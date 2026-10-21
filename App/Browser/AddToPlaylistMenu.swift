import AudioCore
import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// "Add to Playlist ▸" (#0136): editable playlists, recent first, then "New Playlist…". The result goes to the main
/// window's marquee.
struct AddToPlaylistMenu: View {
    let items: [MediaID]
    let model: PlayerModel

    private var library: LibraryBrowserModel { model.library }

    var body: some View {
        let editor = library.playlistsModel
        if editor.canEdit {
            Menu("Add to Playlist") {
                ForEach(editor.addEntries(excluding: openPlaylist)) { entry in
                    switch entry {
                    case .playlist(let playlist):
                        Button(playlist.name) { model.addToPlaylist(items, playlist) }
                    case .separator:
                        Divider()
                    case .newPlaylist:
                        Button("New Playlist\u{2026}") { editor.askToCreate(adding: items) }
                    }
                }
            }
            .disabled(items.isEmpty)
        }
    }

    /// The playlist being viewed is not offered.
    private var openPlaylist: MediaID? {
        library.section == .playlists ? library.selectedPlaylist?.id : nil
    }
}

extension PlayerModel {
    /// Adds library items to a playlist and says what happened in the marquee (#0136).
    func addToPlaylist(_ items: [MediaID], _ playlist: LibraryPlaylist) {
        let editor = library.playlistsModel
        Task {
            let text = await editor.add(items, to: playlist)
            post(StatusNotice(text: text))
        }
    }

    /// "New Playlist…" from Add to Playlist: creates, adds, then says what happened.
    func createPlaylist(named name: String, adding items: [MediaID]) {
        let editor = library.playlistsModel
        Task {
            if let text = await editor.create(named: name, adding: items) { post(StatusNotice(text: text)) }
        }
    }
}

extension View {
    /// Drops of library tracks and albums onto `playlist` add them, when its tracks can be edited (#0136).
    func addsDroppedItems(to playlist: LibraryPlaylist?, model: PlayerModel) -> some View {
        dropDestination(for: MediaIDTransfer.self) { transfers, _ in
            guard let playlist, playlist.editing.contains(.addRemove), model.library.playlistsModel.canEdit else {
                return false
            }
            let ids = transfers.flatMap(\.ids).filter { $0.kind == .track || $0.kind == .album }
            guard !ids.isEmpty else { return false }
            model.addToPlaylist(ids, playlist)
            return true
        }
    }
}
