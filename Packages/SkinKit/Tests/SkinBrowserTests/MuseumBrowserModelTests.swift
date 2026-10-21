import Foundation
import Testing

@testable import SkinBrowser
@testable import SkinLibrary
@testable import SkinMuseum

private func md5(_ n: Int) -> String { String(format: "%032lx", n) }

private func museumSkin(_ n: Int, prefix: String = "skin") -> MuseumSkin {
    let hash = md5(n)
    return MuseumSkin(
        md5: hash, filename: "\(prefix)\(n)_[S\(n)].wsz",
        screenshotURL: URL(string: "https://r2.webampskins.org/screenshots/\(hash).png")!,
        downloadURL: URL(string: "https://r2.webampskins.org/skins/\(hash).wsz")!,
        museumURL: URL(string: "https://skins.webamp.org/skin/\(hash)")!, nsfw: false)
}

/// Answers pages from a function of the query; records calls. Never touches the network.
private actor StubMuseumClient: MuseumPaging {
    private(set) var calls: [MuseumQuery] = []
    var failure: MuseumError?
    var cached: [MuseumQuery: (MuseumPage, Bool)] = [:]
    var delays: [String: Duration] = [:]
    let total: Int

    init(total: Int = 150) { self.total = total }

    func setFailure(_ error: MuseumError?) { failure = error }
    func setCached(_ page: MuseumPage, for query: MuseumQuery, stale: Bool) { cached[query] = (page, stale) }
    func setDelay(_ delay: Duration, forText text: String) { delays[text] = delay }

    func page(_ query: MuseumQuery) async throws -> MuseumPage {
        calls.append(query)
        if case let .search(text, _, _, _) = query, let delay = delays[text] { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        switch query {
        case let .search(text, offset, _, _):
            return MuseumPage(skins: (offset..<offset + 3).map { museumSkin(1000 + $0, prefix: text) }, total: nil, hasMore: false)
        case let .browse(offset, first, _):
            let end = min(offset + first, total)
            return MuseumPage(skins: (offset..<end).map { museumSkin($0) }, total: total, hasMore: end < total)
        }
    }

    func cachedPage(_ query: MuseumQuery) async -> (page: MuseumPage, isStale: Bool)? {
        cached[query].map { ($0.0, $0.1) }
    }
}

private final class StubDownloader: MuseumDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failure: MuseumError?
    init(failure: MuseumError? = nil) { self.failure = failure }
    var calls: Int { lock.withLock { count } }

    func download(
        _ skin: MuseumSkin, into folder: URL, existing: @escaping @Sendable (String) async throws -> URL?
    ) async throws -> MuseumDownloadResult {
        lock.withLock { count += 1 }
        if let failure { throw failure }
        return .added(folder.appendingPathComponent("Museum/\(skin.filename)"))
    }
}

private struct StubScreenshots: MuseumScreenshotProviding {
    func screenshot(for skin: MuseumSkin) async throws -> Data { Data([0x89]) }
}

@MainActor
private final class Hooks {
    var indexed: [URL] = []
    var nsfwWrites: [Bool] = []
    var nsfw = false
}

@MainActor
private func makeMuseum(
    client: StubMuseumClient = StubMuseumClient(), downloader: StubDownloader = StubDownloader(),
    records: [SkinRecord] = [], folder: URL? = testFolder, pageSize: Int = 60
) -> (MuseumBrowserModel, StubMuseumClient, StubDownloader, RecordingApplier, Hooks, StubSkinIndex) {
    let applier = RecordingApplier()
    let hooks = Hooks()
    let index = StubSkinIndex(records)
    let model = MuseumBrowserModel(
        client: client, downloader: downloader, screenshots: StubScreenshots(), folder: { folder },
        lookup: { index }, indexAdded: { hooks.indexed.append($0) }, applySkin: { applier.record($0) },
        showsNSFW: { hooks.nsfw }, setShowsNSFW: { hooks.nsfwWrites.append($0); hooks.nsfw = $0 },
        pageSize: pageSize, prefetchDistance: 12, searchDelay: .milliseconds(40))
    return (model, client, downloader, applier, hooks, index)
}

@MainActor
@Suite struct MuseumBrowserModelTests {
    private func load(_ model: MuseumBrowserModel) async {
        model.appeared()
        #expect(await waitFor { model.phase == .loaded })
    }

    @Test func appearedLoadsBrowsePage() async {
        let (model, client, _, _, _, _) = makeMuseum()
        #expect(model.phase == .idle)
        #expect(await client.calls.isEmpty)
        await load(model)
        #expect(model.items.count == 60)
        #expect(model.total == 150)
        #expect(model.hasMore)
        #expect(await client.calls == [.browse(offset: 0, first: 60, includeNSFW: false)])
    }

    @Test func typingDebouncesSearch() async {
        let (model, client, _, _, _, _) = makeMuseum()
        await load(model)
        model.searchText = "ze"
        model.searchText = "zel"
        model.searchText = "zelda"
        #expect(await waitFor { model.items.first?.filename.hasPrefix("zelda") == true })
        try? await Task.sleep(for: .milliseconds(80))
        let searches = await client.calls.filter { if case .search = $0 { true } else { false } }
        #expect(searches == [.search(text: "zelda", offset: 0, first: 60, includeNSFW: false)])
    }

    @Test func oneCharacterSearchBrowses() async {
        let (model, client, _, _, _, _) = makeMuseum()
        await load(model)
        model.searchText = "z"
        #expect(model.query == .browse(offset: 0, first: 60, includeNSFW: false))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await client.calls.count == 1)
    }

    @Test func scrollingNearEndLoadsNextPage() async {
        let (model, client, _, _, _, _) = makeMuseum()
        await load(model)
        model.loadMoreIfNeeded(current: model.items[10])
        #expect(await client.calls.count == 1)
        model.loadMoreIfNeeded(current: model.items[55])
        #expect(await waitFor { model.items.count == 120 })
        model.loadMoreIfNeeded(current: model.items[119])
        #expect(await waitFor { model.items.count == 150 })
        #expect(!model.hasMore)
        #expect(await client.calls.map { $0.offset } == [0, 60, 120])
    }

    @Test func stalePageIsDropped() async {
        let client = StubMuseumClient()
        await client.setDelay(.milliseconds(300), forText: "slow")
        let (model, _, _, _, _, _) = makeMuseum(client: client)
        await load(model)
        model.searchText = "slow"
        model.searchNow()
        model.searchText = "fast"
        model.searchNow()
        #expect(await waitFor { model.items.first?.filename.hasPrefix("fast") == true })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.items.allSatisfy { $0.filename.hasPrefix("fast") })
    }

    @Test func offlineShowsOfflinePhaseNotSpinner() async {
        let client = StubMuseumClient()
        await client.setFailure(.offline)
        let (model, _, _, _, _, _) = makeMuseum(client: client)
        model.appeared()
        #expect(await waitFor { if case .offline = model.phase { true } else { false } })
        #expect(model.items.isEmpty)
        await client.setFailure(nil)
        model.retry()
        #expect(await waitFor { model.phase == .loaded })
    }

    @Test func offlineWithCacheShowsCachedResults() async {
        let client = StubMuseumClient()
        let query = MuseumQuery.browse(offset: 0, first: 60, includeNSFW: false)
        await client.setCached(MuseumPage(skins: [museumSkin(7)], total: 1, hasMore: false), for: query, stale: true)
        await client.setFailure(.offline)
        let (model, _, _, _, _, _) = makeMuseum(client: client)
        model.appeared()
        #expect(await waitFor { model.usingCachedResults })
        #expect(model.phase == .loaded)
        #expect(model.items.map(\.md5) == [md5(7)])
    }

    @Test func downloadedSkinsAreBadgedFromIndex() async {
        let had = SkinRecord(id: 1, hash: "h", name: "s3", status: .ok, primaryPath: "Old/s3.wsz", md5: md5(3))
        let (model, _, _, _, _, _) = makeMuseum(records: [had])
        await load(model)
        #expect(await waitFor { model.downloaded[md5(3)] != nil })
        #expect(model.downloaded == [md5(3): testFolder.appending(path: "Old/s3.wsz")])
        #expect(model.isDownloaded(museumSkin(3)))
        #expect(!model.isDownloaded(museumSkin(4)))
    }

    @Test func primaryActionDownloadsIndexesAndApplies() async {
        let (model, _, downloader, applier, hooks, _) = makeMuseum()
        await load(model)
        let skin = model.items[5]
        #expect(model.primaryAction(for: skin) == .started)
        #expect(model.downloads[skin.md5] == .running)
        #expect(await waitFor { applier.applied.count == 1 })
        let url = testFolder.appending(path: "Museum/\(skin.filename)")
        #expect(applier.applied == [url])
        #expect(applier.onMainActor == [true])
        #expect(hooks.indexed == [url])
        #expect(downloader.calls == 1)
        #expect(model.downloaded[skin.md5] == url)
        #expect(model.downloads[skin.md5] == nil)
    }

    @Test func primaryActionOnDownloadedSkinAppliesWithoutDownloading() async {
        let had = SkinRecord(id: 1, hash: "h", name: "s3", status: .ok, primaryPath: "Museum/s3.wsz", md5: md5(3))
        let (model, _, downloader, applier, hooks, _) = makeMuseum(records: [had])
        await load(model)
        #expect(await waitFor { model.downloaded[md5(3)] != nil })
        #expect(model.primaryAction(for: museumSkin(3)) == .applied)
        #expect(applier.applied == [testFolder.appending(path: "Museum/s3.wsz")])
        #expect(downloader.calls == 0)
        #expect(hooks.indexed.isEmpty)
    }

    @Test func primaryActionWithoutFolderAsksForFolder() async {
        let (model, _, downloader, applier, _, _) = makeMuseum(folder: nil)
        await load(model)
        #expect(model.primaryAction(for: model.items[0]) == .needsFolder)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(downloader.calls == 0)
        #expect(applier.applied.isEmpty)
    }

    @Test func togglingNSFWReloads() async {
        let (model, client, _, _, hooks, _) = makeMuseum()
        await load(model)
        model.showsNSFW = true
        #expect(hooks.nsfwWrites == [true])
        #expect(await waitFor { await client.calls.count == 2 })
        #expect(await client.calls.last == .browse(offset: 0, first: 60, includeNSFW: true))
        #expect(await waitFor { model.phase == .loaded })
    }

    @Test func failedDownloadShowsErrorOnThatCell() async {
        let (model, _, _, applier, _, _) = makeMuseum(downloader: StubDownloader(failure: .checksumMismatch))
        await load(model)
        let skin = model.items[2]
        model.primaryAction(for: skin)
        #expect(await waitFor { model.downloads[skin.md5] == .failed("The download was corrupted.") })
        #expect(model.downloads[model.items[3].md5] == nil)
        #expect(applier.applied.isEmpty)
        #expect(model.downloaded[skin.md5] == nil)
    }
}
