import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct ArtistListView: View {
    let library: LibraryBrowserModel

    var body: some View {
        PagedListView(
            list: library.artists, rows: library.artistRows, emptyText: "No artists",
            selectedID: library.selectedArtist?.id, onSelect: { library.select($0) }
        ) { artist in
            Text(artist.name).lineLimit(1)
        }
        .accessibilityIdentifier("library.artists")
    }
}

struct PlaylistListView: View {
    let library: LibraryBrowserModel

    var body: some View {
        PagedListView(
            list: library.playlists, rows: library.playlists.items, emptyText: "No playlists",
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
