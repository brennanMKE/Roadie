import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct SearchResultsView: View {
    let library: LibraryBrowserModel
    @Environment(PlayerModel.self) private var player
    @State private var selection = Set<MediaID>()

    var body: some View {
        Group {
            switch library.search {
            case .idle, .searching:
                ProgressView("Searching\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Search failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { library.searchNow() }
                        .accessibilityIdentifier("library.retry")
                }
            case .loaded(let results):
                if results.isEmpty {
                    ContentUnavailableView.search(text: library.searchText)
                } else {
                    List(selection: $selection) {
                        if !results.artists.isEmpty {
                            Section("Artists") {
                                ForEach(ArtistGrouper.group(results.artists)) { group in
                                    Button { library.select(group) } label: {
                                        HStack(spacing: 8) {
                                            AlbumArtView(ref: group.artwork, side: 28)
                                            Text(group.name).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !results.albums.isEmpty {
                            Section("Albums") {
                                ForEach(results.albums) { album in
                                    Button { library.select(album) } label: {
                                        AlbumRow(album: album).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .libraryContainerMenu(album.id, favorite: album.isFavorite, model: player)
                                    .libraryDraggable([album.id])
                                }
                            }
                        }
                        if !results.tracks.isEmpty {
                            Section("Tracks") {
                                ForEach(results.tracks) { track in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).lineLimit(1)
                                        Text(ArtistName.display(track.artistName)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .libraryDraggable([track.id])
                                }
                            }
                        }
                    }
                    .libraryTrackActions(rows: results.tracks, album: nil, model: player)
                }
            }
        }
        .accessibilityIdentifier("library.results")
    }
}
