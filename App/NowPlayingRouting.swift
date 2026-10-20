import AudioCore
import Foundation
import MusicBackendKit

/// Media keys and Control Center commands: to the local `Player` while the local queue feeds This Mac, else to the selected
/// speaker through `PlayerModel`'s command stream (#0064).
@MainActor
final class NowPlayingRouting: NowPlayingCommandTarget {
    private let player: Player
    private weak var model: PlayerModel?

    init(player: Player, model: PlayerModel) {
        self.player = player
        self.model = model
    }

    private var remote: PlayerModel? {
        guard let model, !model.playsLocalQueue else { return nil }
        return model
    }

    func play() { if let remote { remote.send(.play) } else { player.play() } }
    func pause() { if let remote { remote.send(.pause) } else { player.pause() } }
    func togglePlayPause() { if let remote { remote.send(.togglePlayPause) } else { player.togglePlayPause() } }
    func stop() { if let remote { remote.send(.stop) } else { player.stop() } }
    func next() { if let remote { remote.send(.next) } else { player.next() } }
    func previous() { if let remote { remote.send(.previous) } else { player.previous() } }
    func seek(to seconds: TimeInterval) { if let remote { remote.send(.seek(seconds)) } else { player.seek(to: seconds) } }
}
