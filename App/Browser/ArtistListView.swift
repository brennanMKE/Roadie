import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct ArtistListView: View {
    let library: LibraryBrowserModel
    @Environment(PlayerModel.self) private var player

    var body: some View {
        PagedListView(
            list: library.artists, rows: library.artistRows,
            // The last member is the furthest into the loaded list; any member is in `artists.items`.
            pagingID: { $0.members[$0.members.count - 1].id }, emptyText: "No artists",
            selectedID: library.selectedArtistGroup?.id, onSelect: { library.select($0) }
        ) { group in
            let artist = group.members[0]
            FavoriteRow(id: artist.id, stored: artist.isFavorite) {
                HStack(spacing: 8) {
                    AlbumArtView(ref: group.artwork, side: 28)
                    Text(group.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            // A name grouped across providers drags (and plays) its first member only: all of them would queue the
            // same songs once per provider. No double-click: a click opens the artist, and an extra gesture could block the drag.
            .libraryContainerMenu(artist.id, favorite: artist.isFavorite, model: player, addsToPlaylists: false)
            .libraryDraggable([artist.id])
        }
        .accessibilityIdentifier("library.artists")
    }
}

struct PlaylistListView: View {
    let library: LibraryBrowserModel
    @Environment(PlayerModel.self) private var player

    private var model: PlaylistsModel { library.playlistsModel }

    @ViewBuilder
    private func playlistMenu(_ playlist: LibraryPlaylist) -> some View {
        if model.canEdit {
            Button("New Playlist\u{2026}") { model.askToCreate() }
            Divider()
            Button("Rename\u{2026}") { model.askToRename(playlist) }
                .disabled(!model.canRename(playlist))
                .help(model.refusal(for: playlist) ?? "")
                .accessibilityIdentifier("library.playlist.rename")
            Button("Delete\u{2026}") { model.askToDelete(playlist) }
                .disabled(!model.canDelete(playlist))
                .help(model.refusal(for: playlist) ?? "")
            Divider()
            Button("Export as M3U8\u{2026}") { player.exportLibraryPlaylist(playlist) }
                .disabled(!model.canExport(playlist))
            Button("Import Playlist\u{2026}") { player.importLibraryPlaylist() }
        }
    }

    var body: some View {
        PagedListView(
            list: library.playlists, rows: PlaylistGrouping.rows(library.playlists.items),
            pagingID: { row in
                switch row {
                case .playlist(let playlist): playlist.id
                // A header's paging id is its group's last playlist, which is in `playlists.items`.
                case .header(let group): group.playlists[group.playlists.count - 1].id
                }
            },
            emptyText: "No playlists",
            selectedID: library.selectedPlaylist.map { PlaylistGrouping.Row.playlist($0).id },
            onSelect: { row in
                if case .playlist(let playlist) = row { library.select(playlist) }
            }
        ) { row in
            switch row {
            case .header(let group):
                HStack(spacing: 4) {
                    Text(group.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if group.isReadOnly {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Read-only")
                    }
                }
                .selectionDisabled()
            case .playlist(let playlist):
                FavoriteRow(id: playlist.id, stored: playlist.isFavorite) {
                    HStack {
                        Text(playlist.name).lineLimit(1)
                        Spacer()
                        if let count = PlaylistGrouping.countText(playlist) {
                            Text(count).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .padding(.leading, 8)
                // Play works on read-only and dynamic playlists too: playing doesn't edit them (#0189). No Add to
                // Playlist: a playlist can't be added into a playlist.
                .libraryContainerMenu(playlist.id, favorite: playlist.isFavorite, model: player, addsToPlaylists: false) {
                    Divider()
                    playlistMenu(playlist)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded { player.playFromLibrary(.play(container: playlist.id)) })
                .libraryDraggable([playlist.id])
                .addsDroppedItems(to: playlist, model: player)
            }
        }
        .onDeleteCommand { if let playlist = library.selectedPlaylist { model.askToDelete(playlist) } }
        .background {
            // ⌘⌫ deletes the selected playlist (with the confirmation).
            Button("Delete Playlist") { if let playlist = library.selectedPlaylist { model.askToDelete(playlist) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(library.selectedPlaylist.map { !model.canDelete($0) } ?? true)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PlaylistMessageBar(model: model) }
        .accessibilityIdentifier("library.playlists")
    }
}
