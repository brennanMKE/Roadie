import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The sidebar's Discover group (#0143): the server's default rows, or every row with Show all rows.
struct DiscoverSidebarSection<RowLabel: View>: View {
    let discover: DiscoverModel
    @ViewBuilder let label: (RecommendationRow) -> RowLabel

    var body: some View {
        Section {
            switch discover.rows {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed:
                Button("Retry") { discover.reloadRows() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("library.discover.retry")
            case .loaded:
                ForEach(discover.visibleRows) { row in label(row) }
                if discover.hiddenByDefaultCount > 0 {
                    @Bindable var model = discover
                    Toggle("Show all rows", isOn: $model.showAll)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .selectionDisabled()
                        .accessibilityIdentifier("library.discover.showAll")
                }
            }
        } header: {
            Text("Discover")
        }
    }
}

/// The selected Discover row's items, mixed kinds: double-click plays, Play All plays the row as one queue.
struct DiscoverRowView: View {
    let library: LibraryBrowserModel
    let discover: DiscoverModel
    @Environment(PlayerModel.self) private var player
    @State private var selection = Set<RecommendationItem.ID>()

    var body: some View {
        if let row = discover.selectedRow {
            content(row)
                .accessibilityIdentifier("library.discover.items")
                .navigationTitle(row.name)
        } else {
            ContentUnavailableView("Select a row", systemImage: MDIIcon.fallback)
        }
    }

    @ViewBuilder
    private func content(_ row: RecommendationRow) -> some View {
        switch discover.state(of: row.id) {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: row.id) { discover.loadItemsIfNeeded(row) }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load \(row.name)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { discover.refresh(row) }
            }
        case .loaded(let items):
            VStack(alignment: .leading, spacing: 0) {
                header(row, items: items)
                if items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: MDIIcon.symbol(row.icon),
                                           description: Text(row.subtitle ?? ""))
                } else {
                    List(items, selection: $selection) { item in
                        DiscoverItemRow(item: item)
                    }
                    .contextMenu(forSelectionType: RecommendationItem.ID.self) { ids in
                        let picked = playable(ids, in: items)
                        Button("Play") { play(picked) }.disabled(picked.isEmpty)
                        Button("Add to Queue") { player.playFromLibrary(request(picked, mode: .append)) }
                            .disabled(picked.isEmpty)
                    } primaryAction: { ids in
                        play(playable(ids, in: items))
                    }
                }
            }
        }
    }

    private func header(_ row: RecommendationRow, items: [RecommendationItem]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.title3.bold()).lineLimit(1)
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Play All", systemImage: "play.fill") { play(items.compactMap(\.mediaID)) }
                .disabled(items.allSatisfy { $0.mediaID == nil })
                .accessibilityIdentifier("library.discover.playAll")
            Button("Refresh", systemImage: "arrow.clockwise") { discover.refresh(row) }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("library.discover.refresh")
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 8)
    }

    /// The selected items' ids in display order, skipping kinds that can't be played.
    private func playable(_ ids: Set<RecommendationItem.ID>, in items: [RecommendationItem]) -> [MediaID] {
        items.filter { ids.contains($0.id) }.compactMap(\.mediaID)
    }

    private func play(_ ids: [MediaID]) {
        player.playFromLibrary(request(ids, mode: .replace()))
        // Played rows (recently played) change; the hint refreshes them after a quiet moment.
        if !ids.isEmpty { discover.scheduleRefresh() }
    }

    private func request(_ ids: [MediaID], mode: PlayMode) -> PlayRequest? {
        ids.isEmpty ? nil : PlayRequest(items: ids, mode: mode)
    }
}

struct DiscoverItemRow: View {
    let item: RecommendationItem

    var body: some View {
        HStack(spacing: 10) {
            AlbumArtView(ref: item.artwork, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: Self.symbol(item.kind))
                .foregroundStyle(.secondary)
                .accessibilityLabel(item.kind?.rawValue ?? "item")
        }
    }

    static func symbol(_ kind: MediaKind?) -> String {
        switch kind {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .track: "music.note"
        case .playlist: "music.note.list"
        case .radio: "antenna.radiowaves.left.and.right"
        case nil: "questionmark.square.dashed"
        }
    }
}
