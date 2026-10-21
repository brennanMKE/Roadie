import Foundation
import MusicBackendKit
import Observation

/// The Discover rows (#0143): fetched on first show and kept for the session; each row's items load, refresh and
/// fail on their own. A refresh hint (an item was played) refreshes the loaded rows once, debounced.
@MainActor @Observable
public final class DiscoverModel {
    public typealias LoadState<Value: Hashable & Sendable> = LibraryBrowserModel.LoadState<Value>
    public typealias RowsLoader = @Sendable () async throws -> [RecommendationRow]
    public typealias ItemsLoader = @Sendable (RecommendationRow) async throws -> [RecommendationItem]

    public static let showAllKey = "discover.showAllRows"

    public private(set) var rows: LoadState<[RecommendationRow]> = .idle
    public private(set) var items: [RecommendationRow.ID: LoadState<[RecommendationItem]>] = [:]
    /// The row the content column shows.
    public var selectedRowID: RecommendationRow.ID?
    public var selectedRow: RecommendationRow? { selectedRowID.flatMap(row(id:)) }
    /// Every row, not only the server's default ones. Remembered in UserDefaults.
    public var showAll: Bool {
        didSet {
            guard showAll != oldValue else { return }
            defaults?.set(showAll, forKey: Self.showAllKey)
        }
    }

    /// The rows the sidebar lists.
    public var visibleRows: [RecommendationRow] {
        guard case .loaded(let all) = rows else { return [] }
        return DiscoverRows.visible(all, showAll: showAll)
    }

    public var hiddenByDefaultCount: Int {
        guard case .loaded(let all) = rows else { return 0 }
        return DiscoverRows.hiddenCount(all)
    }

    public func row(id: RecommendationRow.ID) -> RecommendationRow? {
        guard case .loaded(let all) = rows else { return nil }
        return all.first { $0.id == id }
    }

    public func state(of id: RecommendationRow.ID) -> LoadState<[RecommendationItem]> { items[id] ?? .idle }

    public let refreshDelay: Duration
    @ObservationIgnored private let loadRows: RowsLoader
    @ObservationIgnored private let loadItems: ItemsLoader
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var rowsTask: Task<Void, Never>?
    @ObservationIgnored private var rowsGeneration = 0
    @ObservationIgnored private var itemTasks: [RecommendationRow.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [RecommendationRow.ID: Int] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(
        rows: @escaping RowsLoader, items: @escaping ItemsLoader, defaults: UserDefaults? = .standard,
        refreshDelay: Duration = .milliseconds(1500)
    ) {
        loadRows = rows
        loadItems = items
        self.defaults = defaults
        self.refreshDelay = refreshDelay
        showAll = defaults?.bool(forKey: Self.showAllKey) ?? false
    }

    public convenience init(backend: any MusicBackend, defaults: UserDefaults? = .standard) {
        self.init(
            rows: { try await backend.recommendationRows() }, items: { try await backend.recommendationItems($0) },
            defaults: defaults)
    }

    // MARK: Rows

    /// Fetches the rows unless they are loaded or loading.
    public func loadRowsIfNeeded() {
        switch rows {
        case .idle, .failed: reloadRows()
        case .loading, .loaded: break
        }
    }

    public func reloadRows() {
        rowsTask?.cancel()
        rowsGeneration += 1
        let generation = rowsGeneration
        rows = .loading
        let load = loadRows
        rowsTask = Task { [weak self] in
            do {
                let result = try await load()
                self?.rowsFinished(.loaded(result), generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.rowsFinished(.failed(userMessage(for: error)), generation: generation)
            }
        }
    }

    private func rowsFinished(_ state: LoadState<[RecommendationRow]>, generation: Int) {
        guard generation == rowsGeneration else { return }
        rows = state
    }

    // MARK: Items

    /// Loads a row's items unless they are loaded or loading.
    public func loadItemsIfNeeded(_ row: RecommendationRow) {
        switch state(of: row.id) {
        case .idle, .failed: refresh(row)
        case .loading, .loaded: break
        }
    }

    /// Reloads one row. The row keeps showing its items meanwhile when it has some; a result from an older request
    /// is dropped.
    public func refresh(_ row: RecommendationRow) {
        let id = row.id
        itemTasks[id]?.cancel()
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        if case .loaded = state(of: id) {} else { items[id] = .loading }
        let load = loadItems
        itemTasks[id] = Task { [weak self] in
            do {
                let result = try await load(row)
                self?.itemsFinished(id, .loaded(result), generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.itemsFinished(id, .failed(userMessage(for: error)), generation: generation)
            }
        }
    }

    private func itemsFinished(_ id: RecommendationRow.ID, _ state: LoadState<[RecommendationItem]>, generation: Int) {
        guard generations[id] == generation else { return }
        itemTasks[id] = nil
        items[id] = state
    }

    /// Something was played: refresh every row with items, once, after `refreshDelay` of quiet.
    public func scheduleRefresh() {
        refreshTask?.cancel()
        let delay = refreshDelay
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.refreshLoaded()
        }
    }

    private func refreshLoaded() {
        refreshTask = nil
        guard case .loaded(let all) = rows else { return }
        for row in all {
            if case .loaded = state(of: row.id) { refresh(row) }
        }
    }

    /// Cancels in-flight loads; loaded rows and items stay.
    public func cancel() {
        rowsGeneration += 1
        rowsTask?.cancel()
        rowsTask = nil
        if rows == .loading { rows = .idle }
        refreshTask?.cancel()
        refreshTask = nil
        for (id, task) in itemTasks {
            task.cancel()
            generations[id, default: 0] += 1
            if items[id] == .loading { items[id] = .idle }
        }
        itemTasks = [:]
    }
}
