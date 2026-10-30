import AppKit
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
            selectedID: library.selectedAlbum?.id, onSelect: { library.select($0) },
            // Double-click plays the album, replacing the queue; a click opens it (#0205).
            primaryAction: { player.playFromLibrary(.play(container: $0.id)) },
            menu: { AnyView(LibraryContainerMenuItems(id: $0.id, favorite: $0.isFavorite, model: player)) }
        ) { album in
            AlbumRow(album: album, showsArtist: showsArtist)
                .libraryDraggable([album.id])
                .accessibilityIdentifier(AXID.Library.row("album", album.id.rawValue))
        }
        .accessibilityIdentifier(showsArtist ? "library.albums" : "library.artistAlbums")
    }
}

/// The artist's albums, with the tracks of the chosen album pushed on top.
struct ArtistAlbumsView: View {
    let library: LibraryBrowserModel
    let artistName: String
    /// The album on the stack: `library.selectedAlbum`, a double-click interval late (`pushAfterDoubleClick`).
    @State private var pushed: LibraryAlbum?

    var body: some View {
        @Bindable var library = library
        let path = Binding<[LibraryAlbum]>(
            get: { pushed.map { [$0] } ?? [] },
            set: {
                pushed = $0.last
                library.selectedAlbum = $0.last
            })
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
        .pushAfterDoubleClick(library.selectedAlbum, into: $pushed)
    }
}

extension View {
    /// Moves `pushed` (what a NavigationStack shows) to `selection` (what a list's click selected). It clears at once
    /// and starts as `selection`, but a new selection is pushed only after the double-click interval: pushed at once,
    /// the destination took the double-click's second click, so the list's primary action (play the album) never saw
    /// it (#0205).
    func pushAfterDoubleClick<Value: Hashable & Sendable>(_ selection: Value?, into pushed: Binding<Value?>) -> some View {
        onAppear { pushed.wrappedValue = selection }
            .task(id: selection) {
                guard let selection else {
                    pushed.wrappedValue = nil
                    return
                }
                guard pushed.wrappedValue != selection else { return }
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                if !Task.isCancelled { pushed.wrappedValue = selection }
            }
    }
}
