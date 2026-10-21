import Foundation
import MusicBackendKit
import Observation

public enum ListPhase: Hashable, Sendable {
    /// Nothing requested yet.
    case idle
    /// First page in flight, no items.
    case loading
    /// At least one page answered; empty `items` is the empty state.
    case loaded
    /// The first page failed; `items` is empty.
    case failed(String)
}

/// The text shown for a failure. `MusicBackendError` is already user-facing and carries no URL or token.
func userMessage(for error: any Error) -> String {
    (error as? MusicBackendError)?.errorDescription ?? error.localizedDescription
}

/// One lazily paged column. It knows nothing about the backend; the owner supplies a loader closure.
@MainActor @Observable
public final class PagedList<Item: Identifiable & Hashable & Sendable> where Item.ID: Sendable {
    public typealias Loader = @Sendable (PageRequest) async throws -> Page<Item>

    public private(set) var items: [Item] = []
    public private(set) var phase: ListPhase = .idle
    /// From the last page that reported one.
    public private(set) var total: Int?
    public private(set) var isLoadingMore = false
    /// A later page failed; the items are kept.
    public private(set) var loadMoreError: String?
    public var hasMore: Bool { nextOffset != nil }
    public let pageSize: Int
    /// `loadMoreIfNeeded(current:)` fires when the item is within this many rows of the end.
    public let prefetchDistance: Int

    /// Called with every error a page load throws (not cancellations), as it happens. For the fallback (#0067).
    @ObservationIgnored public var onFailure: (@MainActor (any Error) -> Void)?

    private var nextOffset: Int?
    @ObservationIgnored private var loader: Loader?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var seen: Set<Item.ID> = []

    public init(pageSize: Int = 100, prefetchDistance: Int = 10, loader: Loader? = nil) {
        self.pageSize = max(1, pageSize)
        self.prefetchDistance = max(0, prefetchDistance)
        self.loader = loader
    }

    /// Swap the loader (for example the selected artist changed) and start over. A nil loader resets to `.idle`.
    public func reload(with loader: Loader?) {
        self.loader = loader
        reload()
    }

    /// The same loader, first page again.
    public func reload() {
        task?.cancel()
        generation += 1
        items = []
        seen = []
        total = nil
        nextOffset = nil
        loadMoreError = nil
        isLoadingMore = false
        guard let loader else {
            phase = .idle
            return
        }
        phase = .loading
        let generation = generation
        let request = PageRequest(offset: 0, limit: pageSize)
        task = Task { [weak self] in
            do {
                let page = try await loader(request)
                self?.finish(page, generation: generation, isFirst: true)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error, generation: generation, isFirst: true)
            }
        }
    }

    /// No-op unless a page has loaded, there is another one, and nothing is in flight.
    public func loadMore() {
        guard phase == .loaded, !isLoadingMore, let offset = nextOffset, let loader else { return }
        isLoadingMore = true
        loadMoreError = nil
        let generation = generation
        let request = PageRequest(offset: offset, limit: pageSize)
        task = Task { [weak self] in
            do {
                let page = try await loader(request)
                self?.finish(page, generation: generation, isFirst: false)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error, generation: generation, isFirst: false)
            }
        }
    }

    public func loadMoreIfNeeded(current item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if index >= items.count - prefetchDistance { loadMore() }
    }

    /// For rows that stand for several items (grouped artists): pass the id of any item the row holds.
    public func loadMoreIfNeeded(id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if index >= items.count - prefetchDistance { loadMore() }
    }

    public func retryLoadMore() {
        loadMoreError = nil
        loadMore()
    }

    /// Patches the loaded item with `id` in place (a confirmed favorite, #0141); no-op when it isn't loaded.
    public func update(id: Item.ID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        guard item.id == id else { return }
        items[index] = item
    }

    /// Cancels the in-flight request. Loaded items stay; a first page that never answered goes back to `.idle`.
    public func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isLoadingMore = false
        if phase == .loading { phase = .idle }
    }

    /// Cancels and forgets everything, including the loader.
    public func reset() {
        task?.cancel()
        task = nil
        generation += 1
        loader = nil
        items = []
        seen = []
        total = nil
        nextOffset = nil
        loadMoreError = nil
        isLoadingMore = false
        phase = .idle
    }

    // MARK: Local edits (#0135): optimistic changes the owner applies before the server confirms.

    /// Inserts `item` at `index` (clamped); no-op when its id is already listed.
    public func insert(_ item: Item, at index: Int) {
        guard seen.insert(item.id).inserted else { return }
        items.insert(item, at: min(max(0, index), items.count))
        if let total { self.total = total + 1 }
    }

    /// Replaces the listed item with the same id; false when it isn't listed.
    @discardableResult
    public func replace(_ item: Item) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        items[index] = item
        return true
    }

    /// Removes the item with `id`; returns it and where it was, for a rollback.
    @discardableResult
    public func remove(id: Item.ID) -> (item: Item, index: Int)? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        seen.remove(id)
        if let total { self.total = max(0, total - 1) }
        return (item, index)
    }

    private func finish(_ page: Page<Item>, generation: Int, isFirst: Bool) {
        guard generation == self.generation else { return }
        for item in page.items where seen.insert(item.id).inserted {
            items.append(item)
        }
        if let total = page.total { self.total = total }
        // A backend that always sets `nextOffset` must still end on an empty page.
        nextOffset = page.items.isEmpty ? nil : page.nextOffset
        isLoadingMore = false
        phase = .loaded
    }

    private func fail(_ error: any Error, generation: Int, isFirst: Bool) {
        guard generation == self.generation else { return }
        onFailure?(error)
        let message = userMessage(for: error)
        if isFirst {
            phase = .failed(message)
        } else {
            isLoadingMore = false
            loadMoreError = message
        }
    }
}
