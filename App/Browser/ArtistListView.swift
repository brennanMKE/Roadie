import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct ArtistListView: View {
    let library: LibraryBrowserModel

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
            .contextMenu { FavoriteMenuItem(items: [artist.id: artist.isFavorite]) }
        }
        .accessibilityIdentifier("library.artists")
    }
}

struct PlaylistListView: View {
    let library: LibraryBrowserModel

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
                .contextMenu { FavoriteMenuItem(items: [playlist.id: playlist.isFavorite]) }
            }
        }
        .accessibilityIdentifier("library.playlists")
    }
}
