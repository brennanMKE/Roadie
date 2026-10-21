import MusicBackendKit
import SwiftUI

extension View {
    /// Double-click (or Return) plays; the context menu offers Play and Add to Playlist. Attach to the
    /// list of `rows`; `album` is the album the rows belong to, nil for search results.
    func libraryTrackActions(rows: [LibraryTrack], album: MediaID?, model: PlayerModel) -> some View {
        contextMenu(forSelectionType: MediaID.self) { ids in
            Button("Play") { model.playFromLibrary(.play(ids, in: rows, album: album)) }
                .disabled(ids.isEmpty)
            Button("Add to Playlist") { model.playFromLibrary(.append(ids, in: rows)) }
                .disabled(ids.isEmpty)
            Divider()
            FavoriteMenuItem(items: Dictionary(
                rows.filter { ids.contains($0.id) }.map { ($0.id, $0.isFavorite) },
                uniquingKeysWith: { first, _ in first }))
        } primaryAction: { ids in
            model.playFromLibrary(.play(ids, in: rows, album: album))
        }
    }

    /// Album rows in a selectable list: double-click plays the album, replacing the queue; the
    /// context menu adds Add to Playlist. Single click keeps selecting (opening) the album: the
    /// double-click is a simultaneous gesture so it never takes the click from the List's selection.
    func libraryAlbumActions(_ album: MediaID, favorite: Bool? = nil, model: PlayerModel) -> some View {
        libraryAlbumMenu(album, favorite: favorite, model: model)
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.playFromLibrary(.play(album: album)) })
    }

    /// Context menu only, for album rows that are buttons.
    func libraryAlbumMenu(_ album: MediaID, favorite: Bool? = nil, model: PlayerModel) -> some View {
        contextMenu {
            Button("Play") { model.playFromLibrary(.play(album: album)) }
            Button("Add to Playlist") { model.playFromLibrary(.append(album: album)) }
            Divider()
            FavoriteMenuItem(items: [album: favorite])
        }
    }
}
