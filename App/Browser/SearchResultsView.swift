import LibraryBrowser
import MusicBackendKit
import SwiftUI

struct SearchResultsView: View {
    let library: LibraryBrowserModel

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
                    List {
                        if !results.artists.isEmpty {
                            Section("Artists") {
                                ForEach(results.artists) { artist in
                                    Button { library.select(artist) } label: {
                                        Text(artist.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
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
                                }
                            }
                        }
                        if !results.tracks.isEmpty {
                            Section("Tracks") {
                                ForEach(results.tracks) { track in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).lineLimit(1)
                                        Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("library.results")
    }
}
