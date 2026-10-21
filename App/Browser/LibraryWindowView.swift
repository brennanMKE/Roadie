import LibraryBrowser
import MusicAssistantKit
import MusicBackendKit
import SwiftUI

/// The Library window: sections, then the section's list, then albums and tracks. Search lives in the toolbar.
struct LibraryWindowView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryFallbackController.self) private var fallback

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
        .navigationSubtitle(subtitle)
        .onChange(of: library.connection == .connected) { _, connected in
            if connected { Task { await player.refreshOutputs() } }
        }
        .modifier(PlaylistEditingModifier(model: library.playlistsModel))
        .toolbar {
            ToolbarItem {
                OutputPickerView()
            }
            if library.playlistsModel.canEdit {
                ToolbarItem {
                    Button("New Playlist", systemImage: "plus") { library.playlistsModel.askToCreate() }
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(library.connection != .connected)
                        .help("New Playlist")
                        .accessibilityIdentifier("library.playlists.new")
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                    .disabled(library.connection != .connected)
                    .accessibilityIdentifier("library.refresh")
            }
            if library.sections.contains(.radio) {
                ToolbarItem {
                    Button("Add Radio URL\u{2026}", systemImage: "antenna.radiowaves.left.and.right") {
                        library.isAddingRadio = true
                    }
                    .disabled(library.connection != .connected)
                    .accessibilityIdentifier("library.radio.add")
                }
            }
        }
        .sheet(isPresented: $library.isAddingRadio) { AddRadioSheet(library: library) }
        .frame(minWidth: 720, minHeight: 420)
    }

    /// The source in use; with Music Assistant and several servers, the chosen server's real name (#0124). The
    /// address and selection reason stay in Settings.
    private var subtitle: String {
        let base = FallbackText.subtitle(fallback.status)
        if player.sources.selectedID == player.musicAssistant.sourceID,
           let name = player.musicAssistantSelection.libraryName {
            return base + " \u{00B7} " + name
        }
        return base
    }

    /// #0104: no Music Assistant server in use while it is the preferred source (none configured or none reachable).
    private var showsDiscovery: Bool {
        player.sources.preferredID == player.musicAssistant.sourceID && player.musicAssistantSelection.current == nil
            && !(player.sources.selectedID == player.musicAssistant.sourceID && player.library.connection == .connected)
    }

    private func contentColumn(_ library: LibraryBrowserModel) -> some View {
        contentList(library)
            .safeAreaInset(edge: .bottom) {
                if showsDiscovery { LibraryDiscoveryBanner() }
            }
    }

    @ViewBuilder
    private func contentList(_ library: LibraryBrowserModel) -> some View {
        if library.connection != .connected {
            LibraryStatusView(library: library)
        } else if library.isSearching {
            SearchResultsView(library: library)
        } else {
            switch library.section {
            case .artists: ArtistListView(library: library)
            case .albums: AlbumListView(library: library, list: library.allAlbums, showsArtist: true)
            case .playlists: PlaylistListView(library: library)
            case .discover:
                if let discover = library.discover {
                    DiscoverRowView(library: library, discover: discover)
                }
            case .favorites: FavoriteKindsView(favorites: library.favorites)
            case .radio: RadioListView(library: library)
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
            case .discover:
                ContentUnavailableView(
                    library.discover?.selectedRow?.name ?? "Discover",
                    systemImage: MDIIcon.symbol(library.discover?.selectedRow?.icon),
                    description: Text("Double-click an item to play it."))
            case .favorites:
                FavoritesDetailView(library: library, favorites: library.favorites)
            case .radio:
                ContentUnavailableView(
                    "Radio", systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Double-click a station to play it."))
            }
        }
    }
}
