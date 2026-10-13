import Foundation
import Observation
import SkinKit

enum PlaybackState {
    case stopped, playing, paused
}

@MainActor
@Observable
final class PlayerModel {
    private(set) var skin: Skin?
    private(set) var skinName: String?
    private(set) var errorMessage: String?
    var playbackState: PlaybackState = .stopped
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

    // TODO: Replace with AVAudioEngine playback (AudioCore).
    func play() { playbackState = .playing }
    func pause() { playbackState = playbackState == .paused ? .playing : .paused }
    func stop() { playbackState = .stopped }
    func previous() {}
    func next() {}
    func eject() { isImporting = true }
}
