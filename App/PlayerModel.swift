import AudioCore
import Foundation
import Observation
import SkinKit

@MainActor
@Observable
final class PlayerModel {
    private(set) var skin: Skin?
    private(set) var skinName: String?
    private(set) var errorMessage: String?
    let player = Player()
    var playbackState: PlaybackState { player.state }
    var isImporting = false
    var scale: CGFloat = 2

    private static let lastSkinKey = "lastSkinPath"

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.lastSkinKey) {
            loadSkin(from: URL(filePath: path))
        }
    }

    func loadSkin(from url: URL) {
        Task {
            let result = await Task.detached { Result { try SkinParser.parse(url: url) } }.value
            switch result {
            case .success(let skin):
                self.skin = skin
                skinName = url.deletingPathExtension().lastPathComponent
                errorMessage = nil
                UserDefaults.standard.set(url.path, forKey: Self.lastSkinKey)
                for warning in skin.warnings { print("[\(url.lastPathComponent)] \(warning)") }
            case .failure(let error):
                errorMessage = "\(url.lastPathComponent): \(error)"
            }
        }
    }

    func play() { player.play() }
    func pause() { player.togglePause() }
    func stop() { player.stop() }
    func previous() { player.previous() }
    func next() { player.next() }
    func eject() { isImporting = true }

    /// Temporary drop-to-play path until the open panel lands (0006).
    func playFiles(_ urls: [URL]) {
        let tracks = urls.compactMap { try? Track.file(at: $0) }
        guard !tracks.isEmpty else { return }
        let start = player.queue.tracks.count
        player.enqueue(tracks)
        player.play(at: start)
    }
}
