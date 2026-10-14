import Foundation
import Testing

@testable import SkinBrowser
@testable import SkinLibrary

@MainActor
@Suite struct SkinBrowserModelTests {
    private func load(_ model: SkinBrowserModel) async {
        model.appeared()
        #expect(await waitFor { model.phase == .loaded })
    }

    @Test func appearedLoadsCountsAndTheFirstPage() async {
        let (stub, _, model, _) = makeModel(numbered(500))
        await load(model)
        #expect(model.items.count == 200)
        #expect(model.hasMore)
        #expect(model.counts?.skins == 500)
        #expect(await waitFor { model.matchCount == 500 })
        #expect(model.lastQueryDuration != nil)
        let calls = await stub.calls
        #expect(calls.first == .counts)
        #expect(calls.contains(.skins(SkinQuery(limit: 200, offset: 0))))
        #expect(calls.contains(.count(SkinQuery(limit: 200, offset: 0))))
    }

    @Test func noFolderShowsNeedsFolder() async {
        let (stub, _, model, _) = makeModel(numbered(5), noIndex: true)
        model.appeared()
        #expect(await waitFor { model.phase == .needsFolder })
        #expect(await stub.calls.isEmpty)
        #expect(!model.canNavigate)
    }

    @Test func appearedTwiceDoesNotReloadLoadedPages() async {
        let (stub, _, model, _) = makeModel(numbered(50))
        await load(model)
        model.appeared()
        #expect(await waitFor { await stub.calls.filter { $0 == .counts }.count == 2 })
        #expect(await stub.skinsCalls.count == 1)
        #expect(model.phase == .loaded)
    }

    @Test func loadMoreIfNeededFiresOnlyNearTheEnd() async {
        let (stub, _, model, _) = makeModel(numbered(450))
        await load(model)
        model.loadMoreIfNeeded(current: model.items[100])
        #expect(await stub.skinsCalls.count == 1)
        model.loadMoreIfNeeded(current: model.items[170])
        #expect(await waitFor { model.items.count == 400 })
        #expect(await stub.skinsCalls.map(\.offset) == [0, 200])
        model.loadMoreIfNeeded(current: model.items[399])
        #expect(await waitFor { model.items.count == 450 })
        #expect(!model.hasMore)
        model.loadMoreIfNeeded(current: model.items[449])
        #expect(await stub.skinsCalls.count == 3)
    }

    @Test func loadMoreIsNotRepeatedWhileInFlight() async {
        let (stub, _, model, _) = makeModel(numbered(500))
        await load(model)
        await stub.gateSkins()
        for _ in 0..<5 { model.loadMoreIfNeeded(current: model.items[199]) }
        #expect(await waitFor { await stub.suspendedCount == 1 })
        #expect(model.isLoadingMore)
        #expect(await stub.skinsCalls.count == 2)
        await stub.releaseSkins()
        #expect(await waitFor { model.items.count == 400 })
        #expect(!model.isLoadingMore)
    }

    @Test func aFailedLaterPageKeepsTheItems() async {
        let (stub, _, model, _) = makeModel(numbered(500))
        await load(model)
        await stub.setSkinsError(StubFailure())
        model.loadMoreIfNeeded(current: model.items[199])
        #expect(await waitFor { model.loadMoreError == "stub failure" })
        #expect(model.items.count == 200)
        #expect(model.hasMore)
        #expect(model.phase == .loaded)
        await stub.setSkinsError(nil)
        model.retryLoadMore()
        #expect(await waitFor { model.items.count == 400 })
        #expect(model.loadMoreError == nil)
    }

    @Test func aFailedFirstPageShowsTheMessage() async {
        let (stub, _, model, _) = makeModel(numbered(5))
        await stub.setSkinsError(StubFailure())
        model.appeared()
        #expect(await waitFor { model.phase == .failed("stub failure") })
    }

    @Test func searchIsDebouncedToOneQuery() async {
        let (stub, _, model, _) = makeModel([
            record(1, "dragon fire"), record(2, "matrix"), record(3, "neon", readme: "a dragon inside"),
        ])
        await load(model)
        model.searchText = "dr"
        model.searchText = "dra"
        model.searchText = "drag"
        #expect(await waitFor { model.items.map(\.id) == [1, 3] })
        let texts = await stub.skinsCalls.map(\.text)
        #expect(texts == ["", "drag"])
        #expect(await waitFor { model.matchCount == 2 })
    }

    @Test func shortQueriesAreAnUnfilteredListing() async {
        let (stub, _, model, _) = makeModel(numbered(20))
        await load(model)
        model.searchText = "d"
        #expect(model.query.text == "")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await stub.skinsCalls.count == 1)
        model.searchText = "dr"
        #expect(await waitFor { await stub.skinsCalls.count == 2 })
        #expect(await stub.skinsCalls.last?.text == "dr")
    }

    @Test func returnSearchesAtOnce() async {
        let (stub, _, model, _) = makeModel(numbered(20), delay: .seconds(5))
        await load(model)
        model.searchText = "skin0003"
        model.searchNow()
        #expect(await waitFor(timeout: 2) { model.items.map(\.name) == ["skin0003"] })
        #expect(await stub.skinsCalls.count == 2)
    }

    @Test func aNewerQueryWinsOverAnOlderAnswer() async {
        let records = [record(1, "abacus"), record(2, "abc")]
        let (stub, _, model, _) = makeModel(records)
        await load(model)
        await stub.gateSkins()
        model.searchText = "ab"
        model.searchNow()
        #expect(await waitFor { await stub.suspendedCount == 1 })
        model.searchText = "abc"
        model.searchNow()
        #expect(await waitFor { await stub.cancelledCount == 1 })
        await stub.releaseSkins()
        #expect(await waitFor { model.phase == .loaded && model.items.map(\.id) == [2] })
    }

    @Test func clearingSearchRestoresTheListing() async {
        let (_, _, model, _) = makeModel(numbered(30))
        await load(model)
        model.searchText = "skin0003"
        #expect(await waitFor { model.items.count == 1 })
        model.clearSearch()
        #expect(model.query.text == "")
        #expect(await waitFor { model.items.count == 30 })
    }

    @Test func statusFilterRestrictsResults() async {
        let records = [record(1, "a"), record(2, "b", status: .partial), record(3, "c", status: .failed)]
        let (stub, _, model, _) = makeModel(records, delay: .seconds(5))
        await load(model)
        model.filter = .failed
        #expect(await waitFor { model.items.map(\.id) == [3] })
        #expect(await stub.skinsCalls.last?.statuses == [.failed])
        model.filter = .all
        #expect(await waitFor { model.items.count == 3 })
        #expect(await stub.skinsCalls.last?.statuses == Set(SkinStatus.allCases))
    }

    @Test func applyCallsTheApplierOnceOnMainWithTheFolderRelativePath() async {
        let item = record(7, "x", path: "sub/x.wsz")
        let (_, applier, model, _) = makeModel([item])
        model.apply(item)
        #expect(applier.applied == [URL(filePath: "/skins/sub/x.wsz")])
        #expect(applier.onMainActor == [true])
        #expect(model.currentSkinID == 7)
    }

    @Test func applyingAFailedSkinIsRefused() async {
        let bad = record(3, "bad", status: .failed)
        let (_, applier, model, _) = makeModel([bad])
        #expect(!model.canApply(bad))
        model.apply(bad)
        #expect(applier.applied.isEmpty)
        #expect(model.currentSkinID == nil)
    }

    @Test func randomAppliesALoadableSkinWhateverTheFilter() async {
        let (stub, applier, model, _) = makeModel([record(1, "a", status: .failed), record(2, "b")])
        await load(model)
        model.filter = .failed
        model.random()
        #expect(await waitFor { applier.applied.count == 1 })
        #expect(await stub.calls.contains(.random([.ok, .partial])))
        #expect(applier.applied == [URL(filePath: "/skins/b.wsz")])
    }

    @Test func randomWithNoLoadableSkinDoesNothing() async {
        let (stub, applier, model, _) = makeModel([record(1, "a", status: .failed)])
        model.random()
        #expect(await waitFor { await stub.calls.contains(.random([.ok, .partial])) })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(applier.applied.isEmpty)
        #expect(model.phase == .idle)
    }

    private func nameOrderRecords() -> [SkinRecord] {
        [record(1, "beta"), record(2, "Alpha", status: .partial), record(3, "Gamma"), record(4, "Delta", status: .failed)]
    }

    @Test func nextAndPreviousWalkNameOrderAndWrap() async {
        let (stub, applier, model, _) = makeModel(nameOrderRecords())
        model.apply(record(2, "Alpha", status: .partial, path: "Alpha.wsz"))
        model.next()
        model.next()
        model.next()
        #expect(await waitFor { applier.applied.count == 4 })
        #expect(applier.applied.dropFirst().map(\.lastPathComponent) == ["beta.wsz", "Gamma.wsz", "Alpha.wsz"])
        model.previous()
        #expect(await waitFor { applier.applied.count == 5 })
        #expect(applier.applied.last?.lastPathComponent == "Gamma.wsz")
        let neighbors = await stub.calls.filter { if case .neighbor = $0 { true } else { false } }
        #expect(neighbors.first == .neighbor(2, .next, [.ok, .partial]))
        #expect(neighbors.last == .neighbor(2, .previous, [.ok, .partial]))
    }

    @Test func nextWithUnknownCurrentStartsAtTheFirstAndPreviousAtTheLast() async {
        let (_, applier, model, _) = makeModel(nameOrderRecords())
        model.next()
        #expect(await waitFor { applier.applied.count == 1 })
        #expect(applier.applied.last?.lastPathComponent == "Alpha.wsz")
        let (_, other, fresh, _) = makeModel(nameOrderRecords())
        fresh.previous()
        #expect(await waitFor { other.applied.count == 1 })
        #expect(other.applied.last?.lastPathComponent == "Gamma.wsz")
    }

    @Test func equalNamesAreVisitedOnceEachInIDOrder() async {
        let (_, applier, model, _) = makeModel([record(1, "skin", path: "1.wsz"), record(2, "Skin", path: "2.wsz"), record(3, "SKIN", path: "3.wsz")])
        for _ in 0..<4 { model.next() }
        #expect(await waitFor { applier.applied.count == 4 })
        #expect(applier.applied.map(\.lastPathComponent) == ["1.wsz", "2.wsz", "3.wsz", "1.wsz"])
    }

    @Test func rapidNextChainsFromTheLatestSelection() async {
        let (_, applier, model, _) = makeModel(numbered(10))
        model.next()
        model.next()
        model.next()
        #expect(await waitFor { applier.applied.count == 3 })
        #expect(applier.applied.map(\.lastPathComponent) == ["skin0001.wsz", "skin0002.wsz", "skin0003.wsz"])
        #expect(model.currentSkinID == 3)
    }

    @Test func skinDidLoadResolvesTheCurrentRecordByPath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "skinbrowser-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "real/copy"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["real/copy/a2.wsz", "real/b.wsz"] { FileManager.default.createFile(atPath: root.appending(path: file).path, contents: Data()) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "real"))

        let (stub, _, model, _) = makeModel([record(1, "a", path: "a.wsz"), record(2, "b", path: "b.wsz")], folder: root.appending(path: "real"))
        await stub.addPath("copy/a2.wsz", for: 1)
        model.skinDidLoad(from: root.appending(path: "real/copy/a2.wsz"))
        #expect(await waitFor { model.currentSkinID == 1 })
        model.skinDidLoad(from: root.appending(path: "link/b.wsz"))
        #expect(await waitFor { model.currentSkinID == 2 })
        model.skinDidLoad(from: URL(filePath: "/elsewhere/a.wsz"))
        #expect(model.currentSkinID == nil)
    }

    @Test func indexDidChangeReloadsCountsAndKeepsTheQuery() async {
        let records = [record(1, "dragon", status: .partial), record(2, "matrix")]
        let (stub, _, model, _) = makeModel(records, delay: .milliseconds(5))
        await load(model)
        model.searchText = "drag"
        model.filter = .partial
        #expect(await waitFor { model.items.map(\.id) == [1] })
        await stub.setRecords(records + [record(3, "dragonfly", status: .partial)])
        model.indexDidChange()
        #expect(await waitFor { model.counts?.skins == 3 && model.items.count == 2 })
        let last = await stub.skinsCalls.last
        #expect(last?.text == "drag")
        #expect(last?.statuses == [.partial])
    }

    @Test func disappearedCancelsInFlightWorkAndKeepsItems() async {
        let (stub, _, model, _) = makeModel(numbered(500))
        await load(model)
        await stub.gateSkins()
        model.loadMoreIfNeeded(current: model.items[199])
        #expect(await waitFor { await stub.suspendedCount == 1 })
        model.disappeared()
        #expect(await waitFor { await stub.cancelledCount == 1 })
        #expect(model.items.count == 200)
        #expect(model.phase == .loaded)
        await stub.releaseSkins()
        model.appeared()
        #expect(await waitFor { await stub.calls.filter { $0 == .counts }.count == 2 })
        #expect(model.items.count == 200)
        #expect(await stub.skinsCalls.count == 2)
    }

    @Test func thumbnailsAskTheProviderWithTheFolderRelativeURL() async {
        let item = record(1, "a", path: "sub/a.wsz")
        let (_, _, model, thumbs) = makeModel([item])
        let image = await model.thumbnail(for: item)
        #expect(image != nil)
        #expect(thumbs.requested == [URL(filePath: "/skins/sub/a.wsz")])
    }

    @Test func canNavigateNeedsALoadableSkin() async {
        let (_, _, onlyFailed, _) = makeModel([record(1, "a", status: .failed)])
        onlyFailed.appeared()
        #expect(await waitFor { onlyFailed.counts != nil })
        #expect(!onlyFailed.canNavigate)
        let (_, _, withPartial, _) = makeModel([record(1, "a", status: .failed), record(2, "b", status: .partial)])
        withPartial.appeared()
        #expect(await waitFor { withPartial.canNavigate })
    }
}
