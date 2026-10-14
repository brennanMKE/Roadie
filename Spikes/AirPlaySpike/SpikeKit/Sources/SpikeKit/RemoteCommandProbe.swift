import Foundation
import MediaPlayer

/// Registers the remote commands a HomePod touch or Siri would send, forwards them to the active engine and
/// logs every one. Publishes Now Playing info on play/pause/seek/track change only.
@MainActor
public final class RemoteCommandProbe {
    public private(set) var lastCommand = "none"
    public var engine: (any SpikeEngine)?
    private let log: SpikeLog
    private var targets: [(MPRemoteCommand, Any)] = []

    public init(log: SpikeLog) {
        self.log = log
        let c = MPRemoteCommandCenter.shared()
        add(c.playCommand, "play") { $0.play() }
        add(c.pauseCommand, "pause") { $0.pause() }
        add(c.togglePlayPauseCommand, "togglePlayPause") { $0.rate > 0 ? $0.pause() : $0.play() }
        add(c.stopCommand, "stop") { $0.pause() }
        add(c.nextTrackCommand, "next") { $0.next() }
        add(c.previousTrackCommand, "previous") { $0.seek(by: -30) }
        for cmd in [c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand] { cmd.isEnabled = false }
        let position = c.changePlaybackPositionCommand
        position.isEnabled = true
        let t = position.addTarget { [weak self] event in
            let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                self.note("changePlaybackPosition \(seconds)")
                engine.seek(by: seconds - engine.currentTime)
            }
            return .success
        }
        targets.append((position, t))
    }

    private func add(_ command: MPRemoteCommand, _ name: String, _ action: @escaping @MainActor (any SpikeEngine) -> Void) {
        command.isEnabled = true
        let t = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.note(name)
                if let engine = self.engine { action(engine) }
            }
            return .success
        }
        targets.append((command, t))
    }

    private func note(_ command: String) {
        lastCommand = command
        log.log(engine?.kind.shortName ?? "-", "remote: \(command) @ \(engine?.currentTime ?? 0)")
    }

    /// Call on play, pause, seek and track change only.
    public func publish(engine: any SpikeEngine, duration: TimeInterval?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "AirPlaySpike \(engine.kind.shortName)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: Double(engine.rate),
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = engine.rate > 0 ? .playing : .paused
    }

    public var playbackStateText: String {
        switch MPNowPlayingInfoCenter.default().playbackState {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        default: "unknown"
        }
    }

    public func tearDown() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
