import Foundation
import Observation
import SkinLibrary
import SkinMuseum
import os

public enum MuseumBrowserPhase: Hashable, Sendable {
    case idle
    /// The first page is in flight and nothing cached is shown.
    case loading
    /// `items` may be empty: that is the empty state.
    case loaded
    /// The Museum can't be reached and nothing is cached for this query.
    case offline(String)
    case failed(String)
}

public enum MuseumDownloadState: Hashable, Sendable {
    case running
    case failed(String)
}

public enum MuseumPrimaryActionResult: Hashable, Sendable {
    /// Already on disk: applied right away.
    case applied
    /// A download started; it indexes and applies when done.
    case started
    /// That skin is already downloading.
    case busy
    /// No skins folder: the UI should offer "Choose Skins Folder…".
    case needsFolder
}

/// Drives the Museum tab of the Skins window: browse/search pages from the Winamp Skin Museum, "Downloaded" badges
/// from the index (by md5), and download → index → apply. No UI, no audio; the network sits behind `MuseumPaging`.
@MainActor
@Observable
public final class MuseumBrowserModel {
    public typealias IndexProvider = @Sendable () async throws -> (any SkinIndexReading)?

    public private(set) var phase: MuseumBrowserPhase = .idle
    public private(set) var items: [MuseumSkin] = []
    public private(set) var total: Int?
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: String?
    /// The shown page came from the result cache because the Museum couldn't be reached.
    public private(set) var usingCachedResults = false
    /// md5 → file in the skins folder, for skins the index already has.
    public private(set) var downloaded: [String: URL] = [:]
    public private(set) var downloads: [String: MuseumDownloadState] = [:]

    public var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    public var showsNSFW: Bool {
        didSet {
            guard showsNSFW != oldValue else { return }
            setShowsNSFW(showsNSFW)
            if phase != .idle { reload() }
        }
    }

    /// Search when the trimmed text has at least two characters, browse otherwise; always the first page.
    public var query: MuseumQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= Self.minimumSearchLength {
            return .search(text: trimmed, offset: 0, first: pageSize, includeNSFW: showsNSFW)
        }
        return .browse(offset: 0, first: pageSize, includeNSFW: showsNSFW)
    }

    public static let minimumSearchLength = 2

    @ObservationIgnored private let client: any MuseumPaging
    @ObservationIgnored private let downloader: any MuseumDownloading
    @ObservationIgnored private let screenshots: any MuseumScreenshotProviding
    @ObservationIgnored private let folder: @MainActor () -> URL?
    @ObservationIgnored private let lookup: IndexProvider
    @ObservationIgnored private let indexAdded: @MainActor (URL) async -> Void
    @ObservationIgnored private let applySkin: @MainActor (URL) -> Void
    @ObservationIgnored private let setShowsNSFW: @MainActor (Bool) -> Void
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let prefetchDistance: Int
    @ObservationIgnored private let searchDelay: Duration
    @ObservationIgnored private var loadedQuery: MuseumQuery?
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private static let logger = Logger(subsystem: "com.brennanmke.SkinAmp", category: "SkinMuseum")

    public init(
        client: any MuseumPaging,
        downloader: any MuseumDownloading,
        screenshots: any MuseumScreenshotProviding,
        folder: @escaping @MainActor () -> URL?,
        lookup: @escaping IndexProvider,
        indexAdded: @escaping @MainActor (URL) async -> Void,
        applySkin: @escaping @MainActor (URL) -> Void,
        showsNSFW: @escaping @MainActor () -> Bool,
        setShowsNSFW: @escaping @MainActor (Bool) -> Void,
        pageSize: Int = MuseumQuery.pageSize, prefetchDistance: Int = 12, searchDelay: Duration = .milliseconds(400)
    ) {
        self.client = client
        self.downloader = downloader
        self.screenshots = screenshots
        self.folder = folder
        self.lookup = lookup
        self.indexAdded = indexAdded
        self.applySkin = applySkin
        self.setShowsNSFW = setShowsNSFW
        self.showsNSFW = showsNSFW()
        self.pageSize = pageSize
        self.prefetchDistance = prefetchDistance
        self.searchDelay = searchDelay
    }

    // MARK: Lifecycle

    /// The Museum tab was shown: the first network use. Loaded pages from an earlier showing stay.
    public func appeared() {
        if phase == .loaded || phase == .loading { return }
        reload()
    }

    /// Cancels the pending search and in-flight loads; the loaded pages stay.
    public func disappeared() {
        searchTask?.cancel()
        moreTask?.cancel()
        isLoadingMore = false
        if phase == .loading {
            loadTask?.cancel()
            generation += 1
            phase = .idle
        }
    }

    public func retry() { reload() }

    /// The index changed (a pass finished): re-badge what's shown.
    public func indexDidChange() {
        let shown = items
        Task { [weak self] in await self?.badge(shown) }
    }

    // MARK: Listing

    public func reload() {
        generation += 1
        let mine = generation
        loadTask?.cancel()
        moreTask?.cancel()
        searchTask?.cancel()
        isLoadingMore = false
        loadMoreError = nil
        usingCachedResults = false
        items = []
        total = nil
        hasMore = false
        phase = .loading
        let request = query
        loadedQuery = request
        nextOffset = 0
        loadTask = Task { [weak self] in
            guard let self else { return }
            let cached = await client.cachedPage(request)
            guard mine == generation, !Task.isCancelled else { return }
            if let cached {
                show(cached.page, for: request)
                if !cached.isStale { return }
            }
            do {
                let page = try await client.page(request)
                guard mine == generation, !Task.isCancelled else { return }
                usingCachedResults = false
                show(page, for: request)
            } catch is CancellationError {
                return
            } catch {
                guard mine == generation, !Task.isCancelled else { return }
                Self.logger.error("museum page failed: \(Self.message(error), privacy: .public)")
                if cached != nil {
                    usingCachedResults = (error as? MuseumError) == .offline
                } else if (error as? MuseumError) == .offline {
                    phase = .offline(Self.message(error))
                } else {
                    phase = .failed(Self.message(error))
                }
            }
        }
    }

    private func show(_ page: MuseumPage, for request: MuseumQuery) {
        items = page.skins
        total = page.total
        hasMore = page.hasMore
        nextOffset = request.first
        phase = .loaded
        let shown = page.skins
        Task { [weak self] in await self?.badge(shown) }
    }

    public func loadMoreIfNeeded(current skin: MuseumSkin) {
        guard hasMore, items.suffix(prefetchDistance).contains(where: { $0.id == skin.id }) else { return }
        loadMore()
    }

    public func retryLoadMore() { loadMore() }

    private func loadMore() {
        guard phase == .loaded, hasMore, !isLoadingMore, let base = loadedQuery else { return }
        isLoadingMore = true
        loadMoreError = nil
        let request = base.withOffset(nextOffset)
        let mine = generation
        moreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await client.page(request)
                guard mine == generation else { return }
                let seen = Set(items.map(\.id))
                let fresh = page.skins.filter { !seen.contains($0.id) }
                items += fresh
                hasMore = page.hasMore
                nextOffset = request.offset + request.first
                isLoadingMore = false
                await badge(fresh)
            } catch {
                guard mine == generation else { return }
                isLoadingMore = false
                if !(error is CancellationError) { loadMoreError = Self.message(error) }
            }
        }
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        guard phase != .idle, query != loadedQuery else { return }
        let delay = searchDelay
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, query != loadedQuery else { return }
            reload()
        }
    }

    /// Return: search without waiting for the debounce.
    public func searchNow() {
        searchTask?.cancel()
        reload()
    }

    // MARK: Badges

    /// One `skins(md5s:)` call per page.
    private func badge(_ skins: [MuseumSkin]) async {
        guard !skins.isEmpty, let root = folder() else { return }
        do {
            guard let reader = try await lookup() else { return }
            let found = try await reader.skins(md5s: skins.map(\.md5))
            // A skin that left the index (moved to the Trash, #0131) loses its badge.
            for skin in skins where found[skin.md5] == nil { downloaded[skin.md5] = nil }
            for (md5, record) in found {
                downloaded[md5] = SkinBrowserFormat.fileURL(folder: root, path: record.primaryPath)
            }
        } catch {
            Self.logger.error("museum badge lookup failed: \(Self.message(error), privacy: .public)")
        }
    }

    // MARK: Primary action

    public func isDownloaded(_ skin: MuseumSkin) -> Bool { downloaded[skin.md5] != nil }

    /// Applies a downloaded skin; otherwise downloads, indexes and applies it.
    @discardableResult
    public func primaryAction(for skin: MuseumSkin) -> MuseumPrimaryActionResult {
        if let url = downloaded[skin.md5] {
            applySkin(url)
            return .applied
        }
        guard let root = folder() else { return .needsFolder }
        if downloads[skin.md5] == .running { return .busy }
        downloads[skin.md5] = .running
        let lookup = self.lookup
        let downloader = self.downloader
        Task { [weak self] in
            do {
                let result = try await downloader.download(skin, into: root) { sha256 in
                    guard let reader = try await lookup(), let record = try await reader.skin(hash: sha256) else {
                        return nil
                    }
                    return SkinBrowserFormat.fileURL(folder: root, path: record.primaryPath)
                }
                guard let self else { return }
                if case .added(let url) = result { await indexAdded(url) }
                downloaded[skin.md5] = result.url
                downloads[skin.md5] = nil
                Self.logger.info("museum skin \(skin.md5, privacy: .public) ready")
                applySkin(result.url)
            } catch {
                guard let self else { return }
                downloads[skin.md5] = .failed(Self.message(error))
            }
        }
        return .started
    }

    // MARK: Screenshots

    /// PNG data; nil on failure (the cell keeps its placeholder).
    public func screenshot(for skin: MuseumSkin) async -> Data? {
        try? await screenshots.screenshot(for: skin)
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension MuseumQuery {
    var offset: Int {
        switch self {
        case .search(_, let offset, _, _), .browse(let offset, _, _): offset
        }
    }

    func withOffset(_ offset: Int) -> MuseumQuery {
        switch self {
        case let .search(text, _, first, nsfw): .search(text: text, offset: offset, first: first, includeNSFW: nsfw)
        case let .browse(_, first, nsfw): .browse(offset: offset, first: first, includeNSFW: nsfw)
        }
    }
}
