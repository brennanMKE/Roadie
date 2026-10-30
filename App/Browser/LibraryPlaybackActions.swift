import LibraryBrowser
import MusicBackendKit
import SwiftUI

extension View {
    /// Double-click (or Return) plays; the context menu offers Play, Play Next, Add to Queue and Add to Playlist ▸. Attach to the
    /// list of `rows`; `album` is the album the rows belong to, nil for search results.
    /// `editor`: the open playlist's editor, which adds Remove from Playlist and Move Up/Down (#0138).
    func libraryTrackActions(
        rows: [LibraryTrack], album: MediaID?, model: PlayerModel, editor: PlaylistEditor? = nil,
        remove: ((Set<MediaID>) -> Void)? = nil
    ) -> some View {
        contextMenu(forSelectionType: MediaID.self) { ids in
            Button("Play") { model.playFromLibrary(.play(ids, in: rows, album: album)) }
                .disabled(ids.isEmpty)
            Button("Play Next") { model.playFromLibrary(.next(ids, in: rows)) }
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

    /// A Library row dragged onto a playlist (#0136) or the playlist editor (#0184, #0188). The one seam to switch to
    /// `.onDrag { NSItemProvider }` if `.draggable` turns out not to put the type on the pasteboard.
    func libraryDraggable(_ ids: [MediaID]) -> some View {
        draggable(MediaIDTransfer(ids))
    }

    /// Context menu only, for container rows (albums, artists, playlists): Play, Play Next, Add to Queue, then Add to
    /// Playlist when `addsToPlaylists`, then the favourite, then `extra` (a Library playlist's edit items, #0189).
    func libraryContainerMenu<Extra: View>(
        _ id: MediaID, favorite: Bool? = nil, model: PlayerModel, addsToPlaylists: Bool = true,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        let extra = extra()
        return contextMenu {
            LibraryContainerMenuItems(id: id, favorite: favorite, model: model, addsToPlaylists: addsToPlaylists)
            extra
        }
    }
}

/// A container's menu items: Play, Play Next, Add to Queue, then Add to Playlist when `addsToPlaylists`, then the
/// favourite. A row's own `libraryContainerMenu`, or a list's `contextMenu(forSelectionType:)` (album lists, #0205).
struct LibraryContainerMenuItems: View {
    let id: MediaID
    var favorite: Bool?
    let model: PlayerModel
    var addsToPlaylists = true

    var body: some View {
        Button("Play") { model.playFromLibrary(.play(container: id)) }
        Button("Play Next") { model.playFromLibrary(.next(container: id)) }
        Button("Add to Queue") { model.playFromLibrary(.append(container: id)) }
        if addsToPlaylists {
            Divider()
            AddToPlaylistMenu(items: [id], model: model)
        }
        FavoriteMenuItem(items: [id: favorite])
    }
}
