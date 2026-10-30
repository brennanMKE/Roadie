import AudioCore
import Foundation

/// UI-test stand-ins for the open and save panels (#0203): XCUITest can't drive `NSOpenPanel` reliably, so under
/// `-RoadieUITest 1` (Debug only) these launch arguments answer the panel instead. Each value is one path, or several
/// separated by `|`.
///
/// - `-RoadieOpenFiles`: the queue at launch (loaded stopped at row 0, nothing plays), and File › Open's answer.
/// - `-RoadieAddFiles`: File › Add to Playlist… and ADD › Add File.
/// - `-RoadieAddFolder`: ADD › Add Folder.
/// - `-RoadieLoadList`: LIST › Load / File › Load Playlist….
/// - `-RoadieSaveTo`: LIST › Save / File › Save Playlist…'s destination (the format follows the extension).
/// - `-RoadieChooseFolder` (#0209): the music-folder panel (Settings › Library, the Welcome); read by
///   `chooseMusicFolder(startingAt:)`, which has no `PlayerModel`.
extension PlayerModel {
    enum PanelStandIn: String {
        case openFiles = "RoadieOpenFiles"
        case addFiles = "RoadieAddFiles"
        case addFolder = "RoadieAddFolder"
        case loadList = "RoadieLoadList"
        case saveTo = "RoadieSaveTo"
    }

    /// The URLs a stand-in gives, or nil (show the real panel). Always nil in Release and outside test mode.
    func panelStandIn(_ standIn: PanelStandIn) -> [URL]? {
        #if DEBUG
        guard configuration.isUITest,
              let raw = UserDefaults.standard.string(forKey: standIn.rawValue), !raw.isEmpty
        else { return nil }
        return raw.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        #else
        return nil
        #endif
    }

    /// `-RoadieOpenFiles` at launch: replaces the queue with those files, stopped (nothing plays). With
    /// `-RoadieVanishingFile N` (#0202), entry N is copied into the data directory, queued from there and the copy
    /// deleted once queued: the sandboxed UI-test runner can't stage a file that goes missing itself.
    func openLaunchFilesForUITest() {
        guard var urls = panelStandIn(.openFiles) else { return }
        var vanishing: URL?
        #if DEBUG
        if let n = configuration.vanishingOpenFile, urls.indices.contains(n), let data = configuration.dataDirectory {
            let copy = data.appending(path: "Vanishing \(urls[n].lastPathComponent)")
            try? FileManager.default.removeItem(at: copy)
            if (try? FileManager.default.copyItem(at: urls[n], to: copy)) != nil {
                urls[n] = copy
                vanishing = copy
            }
        }
        #endif
        Task {
            let result = await LocalTrackLoader.load(urls)
            player.clearQueue()
            player.enqueue(result.tracks)
            if let vanishing { try? FileManager.default.removeItem(at: vanishing) }
        }
    }
}

extension PlayerModel.SystemRequest {
    /// The stand-in that answers this panel in a UI test, if any.
    var standIn: PlayerModel.PanelStandIn? {
        switch self {
        case .openFiles(let replace): replace ? .openFiles : .addFiles
        case .openFolder: .addFolder
        case .openPlaylistFile: .loadList
        case .savePlaylistFile: .saveTo
        default: nil
        }
    }
}
