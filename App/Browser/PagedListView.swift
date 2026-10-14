import LibraryBrowser
import SwiftUI

/// A lazily paged column: spinner, failure, empty text, or a `List` that asks for the next page near its end.
struct PagedListView<Item: Identifiable & Hashable & Sendable, Row: View>: View where Item.ID: Sendable {
    let list: PagedList<Item>
    /// The rows to draw; `list.items` unless a caller maps them (artist grouping).
    let rows: [Item]
    let emptyText: String
    let selectedID: Item.ID?
    let onSelect: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        switch list.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { list.reload() }
            }
        case .loaded:
            if rows.isEmpty {
                ContentUnavailableView(emptyText, systemImage: "music.note")
            } else {
                let selection = Binding<Item.ID?>(
                    get: { selectedID },
                    set: { id in
                        if let id, let item = rows.first(where: { $0.id == id }) { onSelect(item) }
                    })
                List(selection: selection) {
                    ForEach(rows) { item in
                        row(item)
                            .onAppear { list.loadMoreIfNeeded(current: item) }
                    }
                    footer
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if list.isLoadingMore {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
        } else if let error = list.loadMoreError {
            HStack {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { list.retryLoadMore() }
            }
        } else if let label = LibraryFormat.countLabel(list) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}
