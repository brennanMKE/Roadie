import AppKit
import Foundation
import MediaPlayer
import os

/// The transport commands the system can send. `Player` conforms.
@MainActor
public protocol NowPlayingCommandTarget: AnyObject {
    func play()
    func pause()
    func togglePlayPause()
    func stop()
    func next()
    func previous()
    func seek(to seconds: TimeInterval)
}

public enum NowPlayingCommand: Sendable, Equatable {
    case play, pause, togglePlayPause, stop, next, previous
    case seek(TimeInterval)
}

/// Publishes the player's state to `MPNowPlayingInfoCenter` and routes `MPRemoteCommandCenter`
/// commands (media keys, Control Center) back to the player. Updates happen on track change,
/// play/pause/stop and seek only; the system extrapolates the position from elapsed + rate.
@MainActor
public final class NowPlayingBridge {
    private let player: Player
    private let artworkProvider: @Sendable (Track) async -> Data?
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private weak var target: (any NowPlayingCommandTarget)?
    private var tokens: [(MPRemoteCommand, Any)] = []
    private var artwork: (trackID: UUID, data: Data, object: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestedFor: UUID?
    private var installed = false
    private let log = Logger(subsystem: "SkinAmp", category: "NowPlaying")

    public init(
        player: Player,
        artwork: @escaping @Sendable (Track) async -> Data? = EmbeddedArtworkLoader.artwork(for:),
        infoCenter: MPNowPlayingInfoCenter = .default(),
        commandCenter: MPRemoteCommandCenter = .shared()
    ) {
        self.player = player
        self.target = player
        self.artworkProvider = artwork
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
    }

    public func install() {
        guard !installed else { return }
        installed = true
        player.onEvent = { [weak self] event in self?.handle(event) }

        add(commandCenter.playCommand) { _ in .play }
        add(commandCenter.pauseCommand) { _ in .pause }
        add(commandCenter.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(commandCenter.stopCommand) { _ in .stop }
        add(commandCenter.nextTrackCommand) { _ in .next }
        add(commandCenter.previousTrackCommand) { _ in .previous }
        add(commandCenter.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
        // Otherwise Control Center may show +/-15 s skip buttons instead of track skip.
        for command in [
            commandCenter.seekForwardCommand, commandCenter.seekBackwardCommand,
            commandCenter.skipForwardCommand, commandCenter.skipBackwardCommand,
        ] {
            command.isEnabled = false
        }
        publish()
    }

    public func uninstall() {
        guard installed else { return }
        installed = false
        player.onEvent = nil
        for (command, token) in tokens { command.removeTarget(token) }
        tokens = []
        artworkTask?.cancel()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    /// Registers a handler. The closure runs on an unspecified thread, so it extracts a `Sendable`
    /// command from the (non-Sendable) event and hops to the main actor; no `assumeIsolated`.
    private func add<C: MPRemoteCommand>(
        _ command: C, _ map: @escaping @Sendable (MPRemoteCommandEvent) -> NowPlayingCommand?
    ) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] event in
            guard let mapped = map(event) else { return .commandFailed }
            Task { @MainActor in self?.perform(mapped) }
            return .success
        }
        tokens.append((command, token))
    }

    /// Routes a command to the target (also the unit-test seam).
    func perform(_ command: NowPlayingCommand, on override: (any NowPlayingCommandTarget)? = nil) {
        guard let target = override ?? target else { return }
        switch command {
        case .play: target.play()
        case .pause: target.pause()
        case .togglePlayPause: target.togglePlayPause()
        case .stop: target.stop()
        case .next: target.next()
        case .previous: target.previous()
        case .seek(let seconds): target.seek(to: seconds)
        }
    }

    // MARK: State

    private func handle(_ event: PlayerEvent) {
        _ = event
        publish()
    }

    /// Full snapshot of what the player is doing, or nil when nothing should be shown.
    func currentSnapshot() -> NowPlayingSnapshot? {
        guard player.state != .stopped, let track = player.queue.current else { return nil }
        return NowPlayingSnapshot(
            title: track.title, artist: track.artist, album: track.album,
            duration: track.duration,
            elapsed: player.currentTime,
            state: player.state)
    }

    private func publish() {
        guard let snapshot = currentSnapshot() else {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }
        var info = NowPlayingInfoBuilder.info(for: snapshot)
        if let artwork, artwork.trackID == player.queue.current?.id {
            info[MPMediaItemPropertyArtwork] = artwork.object
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = snapshot.state == .playing ? .playing : .paused
        log.debug("published \(snapshot.title, privacy: .public) \(snapshot.elapsed) rate \(snapshot.state == .playing ? 1 : 0)")
        loadArtworkIfNeeded()
    }

    // MARK: Artwork

    private func loadArtworkIfNeeded() {
        guard let track = player.queue.current else { return }
        if artworkRequestedFor == track.id { return }
        artworkRequestedFor = track.id
        artworkTask?.cancel()
        let provider = artworkProvider
        artworkTask = Task { [weak self] in
            let data = await provider(track)
            guard !Task.isCancelled, let self, let data,
                  self.player.queue.current?.id == track.id,
                  let object = Self.makeArtwork(from: data) else { return }
            self.artwork = (track.id, data, object)
            self.publish()
        }
    }

    /// Captures the bytes (not an `NSImage`, which is not `Sendable`) and decodes in the handler.
    /// `nonisolated` so the request handler is not inferred `@MainActor`: MediaPlayer calls it
    /// on its own queue and a main-actor closure would trap there.
    private nonisolated static func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
            NSImage(data: data) ?? NSImage()
        }
    }
}
