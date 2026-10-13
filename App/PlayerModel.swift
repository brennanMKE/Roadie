import AppKit
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
    /// Media keys and Control Center; lives as long as the model.
    private let nowPlaying: NowPlayingBridge
    var playbackState: PlaybackState { player.state }
    var isLoading: Bool { player.state == .loading }
    var scale: CGFloat = 2

    private static let lastSkinKey = "lastSkinPath"

    init() {
        nowPlaying = NowPlayingBridge(player: player)
        nowPlaying.install()
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
    /// Winamp's eject button opens the file dialog.
    func eject() { openFiles(replace: true) }

    /// Shows the open panel for audio files, folders and skins. Open replaces the queue and plays;
    /// Add appends. A chosen `.wsz` loads as the skin. The app is not sandboxed, so the returned
    /// URLs are directly readable.
    func openFiles(replace: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = LocalTrackLoader.audioTypes + [.wsz]
        panel.message = "Choose audio files, folders or a skin"
        panel.prompt = replace ? "Open" : "Add"
        Task {
            guard await panel.begin() == .OK else { return }
            open(panel.urls, replace: replace)
        }
    }

    /// Shows the open panel for skins only.
    func openSkin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.wsz, .zip]
        panel.message = "Choose a skin"
        panel.prompt = "Open"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            loadSkin(from: url)
        }
    }

    /// Routes chosen or dropped URLs: the first `.wsz` loads as the skin (any others are ignored)
    /// and everything else is imported as audio.
    @discardableResult
    func open(_ urls: [URL], replace: Bool) -> Bool {
        let isSkin = { (url: URL) in url.pathExtension.lowercased() == "wsz" }
        let skin = urls.first(where: isSkin)
        let others = urls.filter { !isSkin($0) }
        if let skin { loadSkin(from: skin) }
        importLocalFiles(others, replace: replace)
        return skin != nil || !others.isEmpty
    }

    /// Loads files and folders off the main actor, then queues them. Replacing clears the queue
    /// and starts the first new track; appending only starts playback on an idle, empty player.
    func importLocalFiles(_ urls: [URL], replace: Bool) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await LocalTrackLoader.load(urls)
            guard !result.tracks.isEmpty else {
                if !result.skipped.isEmpty {
                    errorMessage = "Skipped \(result.skipped.count) file(s) \u{2014} see Console"
                }
                return
            }
            let wasIdle = player.state == .stopped && player.queue.tracks.isEmpty
            if replace { player.clearQueue() }
            let start = player.queue.tracks.count
            player.enqueue(result.tracks)
            if replace || wasIdle { player.play(at: start) }
        }
    }
}
