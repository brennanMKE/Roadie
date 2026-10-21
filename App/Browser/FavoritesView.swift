import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The Favorites content column (#0142): one row per kind with its count.
struct FavoriteKindsView: View {
    let favorites: FavoritesModel

    var body: some View {
        let selection = Binding<FavoriteKind?>(
            get: { favorites.selectedKind },
            set: { if let kind = $0 { favorites.selectedKind = kind } })
        List(FavoriteKind.allCases, selection: selection) { kind in
            HStack {
                Label(Self.title(kind), systemImage: Self.symbol(kind))
                Spacer()
                if let count = favorites.counts[kind] {
                    Text(String(count)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .tag(kind)
            .accessibilityIdentifier("library.favorites.\(kind.rawValue)")
        }
        .accessibilityIdentifier("library.favorites")
    }

    static func title(_ kind: FavoriteKind) -> String {
        switch kind {
        case .tracks: "Tracks"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .radios: "Radio"
        }
    }

    static func symbol(_ kind: FavoriteKind) -> String {
        switch kind {
        case .tracks: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .radios: "antenna.radiowaves.left.and.right"
        }
    }
}

/// The Favorites detail: the selected kind's paged list. Albums and playlists push their tracks; an artist opens
/// in Artists. Unfavorited rows leave after the refetch.
struct FavoritesDetailView: View {
    let library: LibraryBrowserModel
    let favorites: FavoritesModel
    @Environment(PlayerModel.self) private var player
    @State private var selectedTrack: MediaID?

    var body: some View {
        let path = Binding<[MediaID]>(
            get: { (library.selectedAlbum?.id ?? library.selectedPlaylist?.id).map { [$0] } ?? [] },
            set: { ids in
                if ids.isEmpty {
                    library.selectedAlbum = nil
                    library.selectedPlaylist = nil
                }
            })
        NavigationStack(path: path) {
            VStack(alignment: .leading, spacing: 0) {
                Text(FavoriteKindsView.title(favorites.selectedKind))
                    .font(.title2.bold())
                    .lineLimit(1)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 8)
                list
            }
            .navigationDestination(for: MediaID.self) { _ in
                TrackListView(library: library)
            }
        }
        .accessibilityIdentifier("library.favorites.detail")
        .onChange(of: favorites.selectedKind) {
            library.selectedAlbum = nil
            library.selectedPlaylist = nil
        }
    }

    @ViewBuilder
    private var list: some View {
        switch favorites.selectedKind {
        case .tracks:
            PagedListView(
                list: favorites.tracks, rows: favorites.tracks.items, pagingID: \.id, emptyText: "No favorite tracks",
                selectedID: selectedTrack, onSelect: { selectedTrack = $0.id }
            ) { track in
                TrackRow(track: track, albumArtist: nil)
            }
            .libraryTrackActions(rows: favorites.tracks.items, album: nil, model: player)
        case .albums:
            AlbumListView(library: library, list: favorites.albums, showsArtist: true)
        case .artists:
            PagedListView(
                list: favorites.artists, rows: favorites.artists.items, pagingID: \.id,
                emptyText: "No favorite artists", selectedID: nil, onSelect: { library.select($0) }
            ) { artist in
                FavoriteRow(id: artist.id, stored: artist.isFavorite) {
                    HStack(spacing: 8) {
                        AlbumArtView(ref: artist.artwork, side: 28)
                        Text(ArtistName.display(artist.name)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .contextMenu { FavoriteMenuItem(items: [artist.id: artist.isFavorite]) }
            }
        case .playlists:
            PagedListView(
                list: favorites.playlists, rows: favorites.playlists.items, pagingID: \.id,
                emptyText: "No favorite playlists", selectedID: library.selectedPlaylist?.id,
                onSelect: { library.select($0) }
            ) { playlist in
                FavoriteRow(id: playlist.id, stored: playlist.isFavorite) {
                    HStack {
                        Text(playlist.name).lineLimit(1)
                        Spacer()
                        if let count = PlaylistGrouping.countText(playlist) {
                            Text(count).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .contextMenu { FavoriteMenuItem(items: [playlist.id: playlist.isFavorite]) }
            }
        case .radios:
            RadioListView(library: library, list: favorites.radios)
        }
    }
}
