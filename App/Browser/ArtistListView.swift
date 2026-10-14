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
            HStack(spacing: 8) {
                AlbumArtView(ref: group.artwork, side: 28)
                Text(group.name).lineLimit(1)
            }
        }
        .accessibilityIdentifier("library.artists")
    }
}

struct PlaylistListView: View {
    let library: LibraryBrowserModel

    var body: some View {
        PagedListView(
            list: library.playlists, rows: library.playlists.items, pagingID: \.id, emptyText: "No playlists",
            selectedID: library.selectedPlaylist?.id, onSelect: { library.select($0) }
        ) { playlist in
            HStack {
                Text(playlist.name).lineLimit(1)
                Spacer()
                if let count = playlist.trackCount {
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityIdentifier("library.playlists")
    }
}
