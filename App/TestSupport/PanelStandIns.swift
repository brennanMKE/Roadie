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

    /// `-RoadieOpenFiles` at launch: replaces the queue with those files, stopped (nothing plays).
    func openLaunchFilesForUITest() {
        guard let urls = panelStandIn(.openFiles) else { return }
        Task {
            let result = await LocalTrackLoader.load(urls)
            player.clearQueue()
            player.enqueue(result.tracks)
        }
    }
}
