import AudioCore
import Foundation
import Observation
import SendspinKit
import os

/// Bridges a Sendspin session ("This Mac" as a Music Assistant player) to AudioCore's `Player`: starts and feeds
/// the player's stream, applies the server's volume and mute, reports local volume changes, and says when local
/// playback took the node away.
@MainActor @Observable
public final class SendspinPlayer {
    public enum Status: Equatable, Sendable {
        case off
        case connecting
        case connected(serverName: String)
        case failed(String)
    }

    public private(set) var status: Status = .off
    public private(set) var isStreaming = false
    public let player: Player
    /// Called when a stream starts (Music Assistant began playing on this Mac, from SkinAmp or elsewhere).
    @ObservationIgnored public var onStreamStarted: (() -> Void)?
    /// Called when local playback took the node (the app asks Music Assistant to stop sending, #0109).
    @ObservationIgnored public var onStreamPreempted: (() -> Void)?
    /// Called when the server ended the stream, or the session dropped or was stopped (#0114); never called for a
    /// local preemption. Runs on the main actor.
    @ObservationIgnored public var onStreamStopped: (() -> Void)?

    @ObservationIgnored private let makeSession: @Sendable (SendspinConnectionConfiguration) -> any SendspinSessionDriving
    @ObservationIgnored private var session: (any SendspinSessionDriving)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observingVolume = false
    @ObservationIgnored private var muted = false
    @ObservationIgnored private var preMuteVolume: Float = 1
    @ObservationIgnored private var lastReported: (volume: Int, muted: Bool)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let log = Logger(subsystem: "co.sstools.roadie", category: "SendspinPlayback")

    /// Starts nothing: no session, no audio device, no network.
    public init(
        player: Player,
        debounce: Duration = .milliseconds(150),
        makeSession: @escaping @Sendable (SendspinConnectionConfiguration) -> any SendspinSessionDriving = {
            SendspinSession(configuration: $0)
        }
    ) {
        self.player = player
        self.debounce = debounce
        self.makeSession = makeSession
        player.addEventObserver { [weak self] event in
            self?.playerEvent(event)
        }
    }

    /// The single PCM format to advertise: 16-bit stereo at the output's rate.
    public func advertisedFormat() -> SendspinAudioFormat {
        SendspinAudioFormat(codec: "pcm", channels: 2, sampleRate: Int(player.streamOutputSampleRate.rounded()), bitDepth: 16)
    }

    /// Connects with `configuration`, stopping any running session first.
    public func start(_ configuration: SendspinConnectionConfiguration) {
        let previous = session
        teardown()
        generation += 1
        let generation = generation
        status = .connecting
        let session = makeSession(configuration)
        self.session = session
        observeVolume()
        eventTask = Task { [weak self] in
            if let previous { await previous.stop(reason: .shutdown) }
            let events = await session.events()
            await session.start()
            for await event in events {
                guard let self, self.generation == generation else { return }
                self.handle(event)
            }
        }
    }

    public func stop(reason: SendspinGoodbyeReason = .shutdown) async {
        let session = self.session
        teardown()
        generation += 1
        endStreamFromServer()
        status = .off
        onStreamStopped?()
        await session?.stop(reason: reason)
    }

    // MARK: Internals

    private func teardown() {
        eventTask?.cancel()
        eventTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        session = nil
        lastReported = nil
    }

    private func handle(_ event: SendspinEvent) {
        switch event {
        case .connected(let hello):
            status = .connected(serverName: hello.name)
            report(force: true)
        case .streamStarted(let format):
            guard format.codec == "pcm", format.bitDepth == 16 || format.bitDepth == 24 else {
                log.error("Sendspin stream format not supported: \(format.codec, privacy: .public) \(format.bitDepth, privacy: .public) bit")
                return
            }
            let streamFormat = StreamFormat(sampleRate: Double(format.sampleRate), channels: format.channels, bitDepth: format.bitDepth)
            if isStreaming, player.isStreaming {
                player.changeStreamFormat(streamFormat)
                return
            }
            do {
                try player.beginStream(streamFormat)
                isStreaming = true
                onStreamStarted?()
            } catch {
                log.error("Sendspin stream could not start: \(String(describing: error), privacy: .public)")
            }
        case .audio(let chunk, let localMicros):
            guard isStreaming else { return }
            player.appendStream(StreamChunk(presentationMicros: localMicros, pcm: chunk.payload))
        case .streamCleared:
            if isStreaming { player.clearStream() }
        case .streamEnded:
            let wasStreaming = isStreaming
            endStreamFromServer()
            if wasStreaming { onStreamStopped?() }
        case .setVolume(let value):
            muted = false
            player.volume = Float(min(max(value, 0), 100)) / 100
            report(force: false)
        case .setMute(let mute):
            if mute, !muted {
                preMuteVolume = player.volume
                muted = true
                player.volume = 0
            } else if !mute, muted {
                muted = false
                player.volume = preMuteVolume
            }
            report(force: false)
        case .disconnected(let error):
            endStreamFromServer()
            status = error.map { Status.failed($0.localizedDescription) } ?? .connecting
            onStreamStopped?()
        case .synchronized, .groupUpdated:
            break
        }
    }

    /// Ends the player's stream without counting it as a preemption.
    private func endStreamFromServer() {
        guard isStreaming else { return }
        isStreaming = false
        player.endStream()
    }

    private func playerEvent(_ event: PlayerEvent) {
        switch event {
        case .streamEnded, .streamPreempted:
            // The bridge clears `isStreaming` before ending a stream itself, so this is local transport.
            guard isStreaming else { return }
            isStreaming = false
            onStreamPreempted?()
        default:
            break
        }
    }

    /// The volume and mute to report: while muted the slider sits at 0 and the remembered level is reported.
    private func currentState() -> (volume: Int, muted: Bool) {
        if muted, player.volume != 0 { muted = false }   // the user moved the slider while muted
        let level = muted ? preMuteVolume : player.volume
        return (Int((level * 100).rounded()), muted)
    }

    private func report(force: Bool) {
        guard let session else { return }
        let state = currentState()
        if !force, let last = lastReported, last == state { return }
        lastReported = state
        Task { await session.report(volume: state.volume, muted: state.muted) }
    }

    private func observeVolume() {
        guard !observingVolume else { return }
        observingVolume = true
        withObservationTracking {
            _ = player.volume
        } onChange: { [weak self] in
            Task { @MainActor in self?.volumeChanged() }
        }
    }

    private func volumeChanged() {
        observingVolume = false
        guard session != nil else { return }
        observeVolume()
        debounceTask?.cancel()
        let debounce = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.report(force: false)
        }
    }
}
