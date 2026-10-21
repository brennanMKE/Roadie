import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct AlbumRow: View {
    let album: LibraryAlbum
    var showsArtist = true

    var body: some View {
        FavoriteRow(id: album.id, stored: album.isFavorite) {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            AlbumArtView(ref: album.artwork, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).lineLimit(1)
                HStack(spacing: 6) {
                    if showsArtist, let artist = album.artistName {
                        Text(ArtistName.display(artist)).foregroundStyle(.secondary)
                    }
                    if let year = album.year {
                        Text(String(year)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Used for both every album and one artist's albums.
struct AlbumListView: View {
    let library: LibraryBrowserModel
    let list: PagedList<LibraryAlbum>
    var showsArtist = true
    @Environment(PlayerModel.self) private var player

    var body: some View {
        PagedListView(
            list: list, rows: list.items, pagingID: \.id, emptyText: "No albums",
            selectedID: library.selectedAlbum?.id, onSelect: { library.select($0) }
        ) { album in
            AlbumRow(album: album, showsArtist: showsArtist)
                .libraryAlbumActions(album.id, favorite: album.isFavorite, model: player)
                .draggable(MediaIDTransfer([album.id]))
        }
        .accessibilityIdentifier(showsArtist ? "library.albums" : "library.artistAlbums")
    }
}

/// The artist's albums, with the tracks of the chosen album pushed on top.
struct ArtistAlbumsView: View {
    let library: LibraryBrowserModel
    let artistName: String

    var body: some View {
        @Bindable var library = library
        let path = Binding<[LibraryAlbum]>(
            get: { library.selectedAlbum.map { [$0] } ?? [] },
            set: { library.selectedAlbum = $0.last })
        NavigationStack(path: path) {
            VStack(alignment: .leading, spacing: 0) {
                Text(artistName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 8)
                AlbumListView(library: library, list: library.artistAlbums, showsArtist: false)
            }
            .navigationDestination(for: LibraryAlbum.self) { _ in
                TrackListView(library: library)
            }
        }
    }
}
