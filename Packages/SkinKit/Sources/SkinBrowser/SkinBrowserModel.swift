import CoreGraphics
import Foundation
import Observation
import SkinLibrary
import os

public enum SkinBrowserPhase: Hashable, Sendable {
    /// No folder is configured (the index closure returned nil).
    case needsFolder
    case idle
    /// The first page is in flight.
    case loading
    /// `items` may be empty: that is the empty state.
    case loaded
    case failed(String)
}

public enum SkinStatusFilter: String, CaseIterable, Sendable, Identifiable {
    case all, ok, partial, failed

    public var id: String { rawValue }

    public var statuses: Set<SkinStatus> {
        switch self {
        case .all: Set(SkinStatus.allCases)
        case .ok: [.ok]
        case .partial: [.partial]
        case .failed: [.failed]
        }
    }

    public var title: String {
        switch self {
        case .all: "All"
        case .ok: "OK"
        case .partial: "Partial"
        case .failed: "Failed"
        }
    }
}

/// Drives the Skins window (listing, search, filter, apply) and the Skins menu (next, previous, random). It talks
/// to the index through `SkinIndexReading` and applies a skin through a closure; it never touches audio.
@MainActor
@Observable
public final class SkinBrowserModel {
    public typealias IndexProvider = @Sendable () async throws -> (any SkinIndexReading)?
    /// Moves a file to the Trash (#0131). Injected so no test touches the real Trash.
    public typealias FileRemover = @Sendable (URL) throws -> Void
    public static let systemTrash: FileRemover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public private(set) var phase: SkinBrowserPhase = .idle
    public private(set) var items: [SkinRecord] = []
    public private(set) var matchCount: Int?
    public private(set) var counts: SkinIndexCounts?
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: String?
    public private(set) var lastQueryDuration: Duration?
    public private(set) var hasMore = false
    public private(set) var currentSkinID: Int64?
    /// The last Move to Trash failure, for a short alert; nil when there is nothing to show (#0131).
    public var trashError: String?
    /// Called after a skin left the index through Move to Trash, so other views (the Museum badges) can refresh.
    @ObservationIgnored public var onTrashed: (@MainActor () -> Void)?

    public var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch(delay: searchDelay) } }
    }
    public var filter: SkinStatusFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }

    public var canNavigate: Bool { (counts?.byStatus[.ok] ?? 0) + (counts?.byStatus[.partial] ?? 0) > 0 }
    public var isFiltered: Bool { query.hasText || filter != .all }

    /// The trimmed text (when it has at least two characters), the filter's statuses, the first page.
    public var query: SkinQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkinQuery(
            text: trimmed.count >= SkinQuery.minimumTextLength ? trimmed : "", statuses: filter.statuses,
            limit: pageSize, offset: 0)
    }

    @ObservationIgnored private let indexProvider: IndexProvider
    @ObservationIgnored private let folder: @MainActor () -> URL?
    @ObservationIgnored private let thumbnails: any SkinThumbnailProviding
    @ObservationIgnored private let applySkin: @MainActor (URL) -> Void
    @ObservationIgnored private let removeFile: FileRemover
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let prefetchDistance: Int
    @ObservationIgnored private let searchDelay: Duration
    @ObservationIgnored private var reader: (any SkinIndexReading)?
    @ObservationIgnored private var loadedQuery: SkinQuery?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var applySerial = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var stepTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private static let logger = Logger(subsystem: "co.sstools.roadie", category: "SkinBrowser")

    public init(
        index: @escaping IndexProvider,
        folder: @escaping @MainActor () -> URL?,
        thumbnails: any SkinThumbnailProviding,
        applySkin: @escaping @MainActor (URL) -> Void,
        removeFile: @escaping FileRemover = SkinBrowserModel.systemTrash,
        pageSize: Int = 200, prefetchDistance: Int = 40, searchDelay: Duration = .milliseconds(150)
    ) {
        indexProvider = index
        self.folder = folder
        self.thumbnails = thumbnails
        self.applySkin = applySkin
        self.removeFile = removeFile
        self.pageSize = pageSize
        self.prefetchDistance = prefetchDistance
        self.searchDelay = searchDelay
    }

    // MARK: Window lifecycle

    /// Opens the index (needsFolder when there is none), reads the counts, and loads the first page unless the
    /// pages from an earlier showing are still there.
    public func appeared() {
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            guard let reader = await resolveReader() else {
                guard !Task.isCancelled else { return }
                items = []
                matchCount = nil
                counts = nil
                if case .failed = phase {} else { phase = .needsFolder }
                return
            }
            await refreshCounts(reader)
            if phase != .loaded { reload() }
        }
    }

    /// Cancels in-flight loads and the pending search; the loaded pages stay.
    public func disappeared() {
        resolveTask?.cancel()
        searchTask?.cancel()
        moreTask?.cancel()
        isLoadingMore = false
        if phase == .loading {
            loadTask?.cancel()
            generation += 1
            phase = .idle
        }
    }

    /// An index pass finished: new counts, and the listing again when it has been shown, keeping text and filter.
    public func indexDidChange() {
        Task { [weak self] in
            guard let self else { return }
            guard let reader = await resolveReader() else {
                counts = nil
                if phase != .idle { items = []; matchCount = nil; phase = .needsFolder }
                return
            }
            await refreshCounts(reader)
            if phase == .needsFolder { phase = .idle }
            if phase == .loaded || phase == .loading { reload() } else if case .failed = phase { reload() }
        }
    }

    // MARK: Listing

    public func reload() {
        guard let reader else {
            appeared()
            return
        }
        generation += 1
        let mine = generation
        loadTask?.cancel()
        moreTask?.cancel()
        isLoadingMore = false
        loadMoreError = nil
        items = []
        matchCount = nil
        hasMore = false
        phase = .loading
        let request = query
        loadedQuery = request
        loadTask = Task { [weak self] in
            let started = ContinuousClock.now
            do {
                let page = try await reader.skins(matching: request)
                guard let self, mine == generation else { return }
                lastQueryDuration = started.duration(to: .now)
                items = page
                hasMore = page.count == request.limit
                phase = .loaded
                Self.logger.debug("page 1: \(page.count) rows")
                let total = try await reader.count(matching: request)
                guard mine == generation else { return }
                matchCount = total
            } catch is CancellationError {
                return
            } catch {
                guard let self, mine == generation else { return }
                if phase == .loaded {
                    Self.logger.error("count failed: \(Self.message(error), privacy: .public)")
                } else {
                    phase = .failed(Self.message(error))
                }
            }
        }
    }

    public func loadMoreIfNeeded(current record: SkinRecord) {
        guard hasMore, items.suffix(prefetchDistance).contains(where: { $0.id == record.id }) else { return }
        loadMore()
    }

    public func retryLoadMore() { loadMore() }

    private func loadMore() {
        guard phase == .loaded, hasMore, !isLoadingMore, let reader, var request = loadedQuery else { return }
        isLoadingMore = true
        loadMoreError = nil
        request.offset = items.count
        let mine = generation
        let page = request
        moreTask = Task { [weak self] in
            do {
                let rows = try await reader.skins(matching: page)
                guard let self, mine == generation else { return }
                let seen = Set(items.map(\.id))
                items += rows.filter { !seen.contains($0.id) }
                hasMore = rows.count == page.limit
                isLoadingMore = false
            } catch {
                guard let self, mine == generation else { return }
                isLoadingMore = false
                if !(error is CancellationError) { loadMoreError = Self.message(error) }
            }
        }
    }

    // MARK: Search

    private func scheduleSearch(delay: Duration) {
        searchTask?.cancel()
        var wanted = query
        wanted.offset = 0
        guard wanted != loadedQuery else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Return: search without waiting for the debounce.
    public func searchNow() {
        searchTask?.cancel()
        if phase == .idle || phase == .needsFolder { return }
        reload()
    }

    public func clearSearch() { searchText = "" }

    // MARK: Applying

    public func canApply(_ record: SkinRecord) -> Bool { record.status != .failed }

    /// Synchronous on the main actor: the hook is called before this returns.
    public func apply(_ record: SkinRecord) {
        guard canApply(record), let folder = folder() else { return }
        applySerial += 1
        currentSkinID = record.id
        Self.logger.info("apply skin \(record.id) (\(record.status.rawValue, privacy: .public))")
        applySkin(SkinBrowserFormat.fileURL(folder: folder, path: record.primaryPath))
    }

    public func random() {
        enqueue { model, reader in
            if let record = try await reader.randomSkin(statuses: SkinQuery.loadable) { model.apply(record) }
        }
    }

    public func next() { step(.next) }
    public func previous() { step(.previous) }

    private func step(_ direction: SkinNeighborDirection) {
        enqueue { model, reader in
            let from = model.currentSkinID ?? -1
            if let record = try await reader.neighbor(of: from, direction: direction, statuses: SkinQuery.loadable) {
                model.apply(record)
            }
        }
    }

    /// Steps run one after another, each reading `currentSkinID` after the previous one applied, so rapid presses chain.
    private func enqueue(_ work: @escaping @MainActor (SkinBrowserModel, any SkinIndexReading) async throws -> Void) {
        let previous = stepTask
        stepTask = Task { [weak self] in
            await previous?.value
            guard let self, let reader = await resolveReader() else { return }
            do { try await work(self, reader) } catch {
                Self.logger.error("skin step failed: \(Self.message(error), privacy: .public)")
            }
        }
    }

    /// The player loaded a skin from `url` (any route): find which index row it is.
    public func skinDidLoad(from url: URL) {
        guard let root = folder(), let path = SkinBrowserFormat.relativePath(of: url, in: root) else {
            currentSkinID = nil
            return
        }
        let serial = applySerial
        Task { [weak self] in
            guard let self, let reader = await resolveReader() else { return }
            let id = try? await reader.skin(atPath: path)?.id
            // A newer apply since this load started owns `currentSkinID`.
            if serial == applySerial { currentSkinID = id }
        }
    }

    // MARK: Move to Trash

    public func moveToTrash(_ record: SkinRecord) {
        Task { await moveToTrash(path: record.primaryPath, name: record.name) }
    }

    /// Moves the file at the folder-relative `path` to the Trash (only that file: a linked duplicate stays) and drops
    /// its row, and the skin's row and thumbnail when it was the last file, without a rescan. A file that is already
    /// gone is just dropped from the index. A skin that is applied stays applied. Returns whether the row went.
    @discardableResult
    public func moveToTrash(path: String, name: String? = nil) async -> Bool {
        let label = name ?? (path as NSString).lastPathComponent
        guard let root = folder() else { return false }
        let url = SkinBrowserFormat.fileURL(folder: root, path: path)
        guard SkinBrowserFormat.relativePath(of: url, in: root) != nil else {
            trashError = "“\(label)” is not in the skins folder."
            return false
        }
        guard let reader = await resolveReader() else { return false }
        do {
            try removeFile(url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            Self.logger.info("trash: file already gone, dropping it from the index")
        } catch {
            trashError = "Couldn’t move “\(label)” to the Trash. \(Self.message(error))"
            return false
        }
        do {
            if let hash = try await reader.removeFile(atPath: path) { await thumbnails.remove(hash: hash) }
        } catch {
            trashError = "“\(label)” was moved to the Trash, but the index could not be updated. \(Self.message(error))"
        }
        items.removeAll { $0.primaryPath == path }
        indexDidChange()
        onTrashed?()
        return true
    }

    // MARK: Thumbnails

    public func thumbnail(for record: SkinRecord) async -> CGImage? {
        guard let folder = folder() else { return nil }
        return await thumbnails.thumbnail(for: record, at: SkinBrowserFormat.fileURL(folder: folder, path: record.primaryPath))
    }

    // MARK: Helpers

    private func resolveReader() async -> (any SkinIndexReading)? {
        if let reader { return reader }
        do {
            let opened = try await indexProvider()
            if let opened { reader = opened }
            return opened
        } catch {
            phase = .failed(Self.message(error))
            return nil
        }
    }

    private func refreshCounts(_ reader: any SkinIndexReading) async {
        do { counts = try await reader.counts() } catch { phase = .failed(Self.message(error)) }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
