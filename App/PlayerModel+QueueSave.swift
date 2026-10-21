import AudioCore
import Foundation
import LibraryBrowser
import MusicBackendKit

/// Playback › Save Queue as Playlist… (#0140): the shown queue, to a file for the local queue (#0132 decision 4) or
/// to a Music Assistant playlist for a speaker or This Mac on the Music Assistant feed.
extension PlayerModel {
    private var queueSaveTarget: QueueSaveTarget {
        let output = selectedOutput
        return QueueSaveTarget.choose(
            output: output, feed: thisMacFeed, capabilities: router.backend(for: output).capabilities)
    }

    var canSaveQueue: Bool { queueSaveTarget != .refused }

    func saveQueue() {
        switch queueSaveTarget {
        case .file:
            savePlaylistFile()
        case .refused:
            post(StatusNotice(text: "Can't save this queue", detail: "This music source has no playlists"))
        case .remote(let output):
            let backend = router.backend(for: output)
            let library = library
            Task {
                guard let name = await SaveQueueSheet.askName() else { return }
                do {
                    try await backend.saveQueueAsPlaylist(on: output, named: name)
                    post(StatusNotice(text: "Saved queue as \u{201C}\(name)\u{201D}"))
                    // Shown: reload now. Hidden: forget it, so it loads fresh when the section is next shown.
                    if library.section == .playlists { library.refresh() } else { library.playlists.reset() }
                } catch {
                    let message = (error as? MusicBackendError)?.errorDescription ?? error.localizedDescription
                    post(StatusNotice(text: "Couldn't save the queue", detail: message))
                }
            }
        }
    }
}
