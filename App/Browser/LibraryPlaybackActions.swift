import LibraryBrowser
import MusicBackendKit
import SwiftUI

extension View {
    /// Double-click (or Return) plays; the context menu offers Play, Add to Queue and Add to Playlist ▸. Attach to the
    /// list of `rows`; `album` is the album the rows belong to, nil for search results.
    /// `editor`: the open playlist's editor, which adds Remove from Playlist and Move Up/Down (#0138).
    func libraryTrackActions(
        rows: [LibraryTrack], album: MediaID?, model: PlayerModel, editor: PlaylistEditor? = nil,
        remove: ((Set<MediaID>) -> Void)? = nil
    ) -> some View {
        contextMenu(forSelectionType: MediaID.self) { ids in
            Button("Play") { model.playFromLibrary(.play(ids, in: rows, album: album)) }
                .disabled(ids.isEmpty)
            // The queue is Winamp's playlist; real playlists get the submenu (#0136).
            Button("Add to Queue") { model.playFromLibrary(.append(ids, in: rows)) }
                .disabled(ids.isEmpty)
            Divider()
            AddToPlaylistMenu(items: Array(ids), model: model)
            FavoriteMenuItem(items: Dictionary(
                rows.filter { ids.contains($0.id) }.map { ($0.id, $0.isFavorite) },
                uniquingKeysWith: { first, _ in first }))
            if let editor, editor.playlist?.editing.contains(.addRemove) == true {
                Divider()
                Button("Remove from Playlist") {
                    if let remove { remove(ids) } else { editor.remove(selected: ids) }
                }
                    .disabled(ids.isEmpty || !editor.canRemove)
                if editor.playlist?.editing.contains(.reorder) == true, ids.count == 1, let id = ids.first {
                    Button("Move Up") { editor.moveUp(id) }
                        .disabled(!editor.canReorder || editor.rows.first?.id == id)
                    Button("Move Down") { editor.moveDown(id) }
                        .disabled(!editor.canReorder || editor.rows.last?.id == id)
                }
            }
        } primaryAction: { ids in
            model.playFromLibrary(.play(ids, in: rows, album: album))
        }
    }

    /// Album rows in a selectable list: double-click plays the album, replacing the queue; the
    /// context menu adds Add to Queue and Add to Playlist ▸. Single click keeps selecting (opening) the album: the
    /// double-click is a simultaneous gesture so it never takes the click from the List's selection.
    func libraryAlbumActions(_ album: MediaID, favorite: Bool? = nil, model: PlayerModel) -> some View {
        libraryAlbumMenu(album, favorite: favorite, model: model)
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.playFromLibrary(.play(album: album)) })
    }

    /// Context menu only, for album rows that are buttons.
    func libraryAlbumMenu(_ album: MediaID, favorite: Bool? = nil, model: PlayerModel) -> some View {
        contextMenu {
            Button("Play") { model.playFromLibrary(.play(album: album)) }
            Button("Add to Queue") { model.playFromLibrary(.append(album: album)) }
            Divider()
            AddToPlaylistMenu(items: [album], model: model)
            FavoriteMenuItem(items: [album: favorite])
        }
    }
}
