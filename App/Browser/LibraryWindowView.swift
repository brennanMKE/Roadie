import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The Library window: sections, then the section's list, then albums and tracks. Search lives in the toolbar.
struct LibraryWindowView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var library = player.library
        NavigationSplitView {
            LibrarySidebarView()
        } content: {
            contentColumn(library)
        } detail: {
            detailColumn(library)
        }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search artists, albums and tracks")
        .onSubmit(of: .search) { library.searchNow() }
        .task(id: ObjectIdentifier(player.library)) { library.appeared() }
        .onDisappear { library.disappeared() }
        .navigationTitle("Library")
        .navigationSubtitle(library.backend.displayName)
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                    .disabled(library.connection != .connected)
                    .accessibilityIdentifier("library.refresh")
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private func contentColumn(_ library: LibraryBrowserModel) -> some View {
        if library.connection != .connected {
            LibraryStatusView(library: library)
        } else if library.isSearching {
            SearchResultsView(library: library)
        } else {
            switch library.section {
            case .artists: ArtistListView(library: library)
            case .albums: AlbumListView(library: library, list: library.allAlbums, showsArtist: true)
            case .playlists: PlaylistListView(library: library)
            }
        }
    }

    @ViewBuilder
    private func detailColumn(_ library: LibraryBrowserModel) -> some View {
        if library.connection != .connected {
            LibraryStatusView(library: library)
        } else {
            switch library.section {
            case .artists:
                if let artist = library.selectedArtist {
                    ArtistAlbumsView(library: library, artistName: library.selectedArtistGroup?.name ?? ArtistName.display(artist.name))
                } else {
                    ContentUnavailableView("Select an artist", systemImage: "music.mic")
                }
            case .albums:
                if library.selectedAlbum != nil {
                    TrackListView(library: library)
                } else {
                    ContentUnavailableView("Select an album", systemImage: "square.stack")
                }
            case .playlists:
                if library.selectedPlaylist != nil {
                    TrackListView(library: library)
                } else {
                    ContentUnavailableView("Select a playlist", systemImage: "music.note.list")
                }
            }
        }
    }
}
