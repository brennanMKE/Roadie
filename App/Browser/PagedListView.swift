import LibraryBrowser
import SwiftUI

/// A lazily paged column: spinner, failure, empty text, or a `List` that asks for the next page near its end.
struct PagedListView<ListItem: Identifiable & Hashable & Sendable, Item: Identifiable, Row: View>: View
where ListItem.ID: Sendable, Item.ID: Hashable {
    let list: PagedList<ListItem>
    /// The rows to draw; `list.items` unless a caller maps them (artist grouping).
    let rows: [Item]
    /// The id of an item in `list.items` that this row holds, so near-the-end rows load the next page.
    let pagingID: (Item) -> ListItem.ID
    let emptyText: String
    let selectedID: Item.ID?
    let onSelect: (Item) -> Void
    /// Double-click or Return on a row, and the row's context menu, as the List's `contextMenu(forSelectionType:)`. A
    /// row-level double-click gesture took single clicks from the selection and blocked the row's drag (#0205), so
    /// container lists (albums) use this instead. nil: no list-level menu (rows bring their own).
    var primaryAction: ((Item) -> Void)? = nil
    var menu: ((Item) -> AnyView)? = nil
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
                let table = List(selection: selection) {
                    ForEach(rows) { item in
                        row(item)
                            .onAppear { list.loadMoreIfNeeded(id: pagingID(item)) }
                    }
                    footer
                }
                if let primaryAction {
                    table.contextMenu(forSelectionType: Item.ID.self) { ids in
                        if let menu, let picked = entry(ids) { menu(picked) }
                    } primaryAction: { ids in
                        if let picked = entry(ids) { primaryAction(picked) }
                    }
                } else {
                    table
                }
            }
        }
    }

    /// The row a list-level menu or primary action is for: the one of `ids` (a single-selection list).
    private func entry(_ ids: Set<Item.ID>) -> Item? {
        ids.first.flatMap { id in rows.first { $0.id == id } }
    }

    @ViewBuilder
    private var footer: some View {
        switch PagedListFooter(list) {
        case .loading:
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
        case .error(let error):
            HStack {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { list.retryLoadMore() }
            }
        case .count(let label):
            Text(label).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .nothing:
            EmptyView()
        }
    }
}

/// The last row of a paged list (#0215): a spinner while the next page loads, its failure with Retry, the
/// "n of m" count, or nothing when the total is unknown.
enum PagedListFooter: Equatable {
    case loading
    case error(String)
    case count(String)
    case nothing

    init(isLoadingMore: Bool, loadMoreError: String?, countLabel: String?) {
        if isLoadingMore {
            self = .loading
        } else if let loadMoreError {
            self = .error(loadMoreError)
        } else if let countLabel {
            self = .count(countLabel)
        } else {
            self = .nothing
        }
    }

    @MainActor
    init<Item>(_ list: PagedList<Item>) {
        self.init(
            isLoadingMore: list.isLoadingMore, loadMoreError: list.loadMoreError,
            countLabel: LibraryFormat.countLabel(list))
    }
}
