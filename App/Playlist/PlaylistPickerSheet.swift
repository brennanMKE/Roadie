import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// LIST › Load on a Music Assistant queue (#0146): the Library's playlists, grouped as in the Playlists list and
/// filtered by name. Load (or a double click) plays the chosen playlist, replacing the queue; nil means cancelled.
struct PlaylistPickerSheet: View {
    let library: LibraryBrowserModel
    let onFinish: (LibraryPlaylist?) -> Void
    @State private var search = ""
    @State private var selection: MediaID?

    private var list: PagedList<LibraryPlaylist> { library.playlists }

    private var matching: [LibraryPlaylist] { Self.matching(list.items, search: search) }

    private var chosen: LibraryPlaylist? { Self.chosen(in: matching, selection: selection) }

    /// The playlists whose names contain the trimmed search, ignoring case; all of them for a blank search (#0218).
    static func matching(_ items: [LibraryPlaylist], search: String) -> [LibraryPlaylist] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The selected playlist when it is still among `matching`.
    static func chosen(in matching: [LibraryPlaylist], selection: MediaID?) -> LibraryPlaylist? {
        matching.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Load Playlist").font(.headline)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("playlist.picker.search")
            List(selection: $selection) {
                ForEach(PlaylistGrouping.groups(matching)) { group in
                    Section(group.title) {
                        ForEach(group.playlists) { playlist in
                            Text(playlist.name)
                                .tag(playlist.id)
                                .onAppear { list.loadMoreIfNeeded(current: playlist) }
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: MediaID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first, let playlist = matching.first(where: { $0.id == id }) { onFinish(playlist) }
            }
            .overlay {
                if matching.isEmpty {
                    Text(list.phase == .loading ? "Loading…" : "No playlists")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 320, minHeight: 300)
            .accessibilityIdentifier("playlist.picker.list")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Load") { onFinish(chosen) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
    }
}
