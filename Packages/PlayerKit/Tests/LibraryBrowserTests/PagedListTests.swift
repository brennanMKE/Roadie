import Foundation
import MusicBackendKit
import Testing
@testable import LibraryBrowser

@MainActor
struct PagedListTests {
    private func makeList(
        _ loader: GatedLoader, pageSize: Int = 10, prefetch: Int = 3
    ) -> PagedList<TestRow> {
        PagedList(pageSize: pageSize, prefetchDistance: prefetch, loader: loader.loader)
    }

    @Test func updatePatchesAnItemInPlace() async {
        let albums = (0..<3).map { LibraryAlbum(id: MediaID(.album, "a\($0)"), title: "A\($0)") }
        let list = PagedList<LibraryAlbum>(pageSize: 10) { request in
            Page.make(items: albums, request: request, total: albums.count)
        }
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        list.update(id: albums[1].id) { $0.isFavorite = true }
        #expect(list.items.map(\.isFavorite) == [nil, true, nil])
        list.update(id: MediaID(.album, "missing")) { $0.isFavorite = true }
        list.update(id: albums[0].id) { $0.id = MediaID(.album, "renamed") }
        #expect(list.items.map(\.id) == albums.map(\.id))
    }

    @Test func reloadLoadsTheFirstPageAndReportsTheTotal() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(list.phase == .loading)
        #expect(await waitFor { list.phase == .loaded })
        #expect(list.items.count == 10)
        #expect(list.total == 25)
        #expect(list.hasMore)
        #expect(loader.requests == [PageRequest(offset: 0, limit: 10)])
    }

    @Test func emptyFirstPageIsLoadedNotFailed() async {
        let loader = GatedLoader(rows: 0, total: 0)
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        #expect(list.items.isEmpty)
        #expect(!list.hasMore)
    }

    @Test func loadMoreIfNeededFiresOnlyNearTheEnd() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        list.loadMoreIfNeeded(current: list.items[2])
        #expect(loader.requests.count == 1)
        list.loadMoreIfNeeded(current: list.items[7])
        #expect(await waitFor { list.items.count == 20 })
        #expect(loader.requests.last == PageRequest(offset: 10, limit: 10))
    }

    @Test func loadMoreAppendsUntilTheLastPage() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        list.loadMore()
        #expect(await waitFor { list.items.count == 20 })
        list.loadMore()
        #expect(await waitFor { list.items.count == 25 })
        #expect(!list.hasMore)
        let sent = loader.requests.count
        list.loadMore()
        #expect(loader.requests.count == sent)
        #expect(list.items.map(\.id) == (0..<25).map { String(format: "r%02d", $0) })
    }

    @Test func loadMoreIsNotRepeatedWhileInFlight() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        loader.gateNext()
        for _ in 0..<5 { list.loadMoreIfNeeded(current: list.items[9]) }
        #expect(await waitFor { loader.waitingCount == 1 })
        #expect(list.isLoadingMore)
        #expect(loader.requests.count == 2)
        loader.release()
        #expect(await waitFor { list.items.count == 20 })
        #expect(!list.isLoadingMore)
        #expect(loader.requests.count == 2)
    }

    @Test func reloadDropsAStaleFirstPage() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        loader.setPrefix("a")
        loader.gateNext()
        list.reload()
        #expect(await waitFor { loader.waitingCount == 1 })
        loader.setPrefix("b")
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        loader.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(list.items.count == 10)
        #expect(list.items.allSatisfy { $0.id.hasPrefix("b") })
        #expect(list.phase == .loaded)
    }

    @Test func aFailedLaterPageKeepsTheItems() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        loader.failNext(.unreachable("Can't reach the server."))
        list.loadMore()
        #expect(await waitFor { list.loadMoreError != nil })
        #expect(list.loadMoreError == "Can't reach the server.")
        #expect(list.items.count == 10)
        #expect(list.hasMore)
        #expect(list.phase == .loaded)
        list.retryLoadMore()
        #expect(await waitFor { list.items.count == 20 })
        #expect(list.loadMoreError == nil)
    }

    @Test func aFailedFirstPageShowsTheMessage() async {
        let loader = GatedLoader()
        let message = "Signed in, but this account can't access this server."
        loader.failNext(.backend(message))
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .failed(message) })
        #expect(list.items.isEmpty)
    }

    @Test func duplicateIDsAcrossPagesAreDropped() async {
        let loader = GatedLoader(rows: 20, total: 20)
        loader.override(index: 10, id: "r03")
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        list.loadMore()
        #expect(await waitFor { list.items.count == 19 })
        #expect(Set(list.items.map(\.id)).count == 19)
    }

    @Test func cancelKeepsLoadedItemsAndDoesNotFail() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        loader.gateNext()
        list.loadMore()
        #expect(await waitFor { loader.waitingCount == 1 })
        list.cancel()
        #expect(await waitFor { loader.cancelledCount == 1 })
        #expect(list.items.count == 10)
        #expect(list.phase == .loaded)
        #expect(list.loadMoreError == nil)
        #expect(!list.isLoadingMore)
    }

    @Test func cancelBeforeTheFirstPageGoesBackToIdle() async {
        let loader = GatedLoader()
        loader.gateNext()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { loader.waitingCount == 1 })
        list.cancel()
        #expect(await waitFor { loader.cancelledCount == 1 })
        #expect(list.phase == .idle)
    }

    @Test func resetGoesBackToIdle() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        list.reset()
        #expect(list.phase == .idle)
        #expect(list.items.isEmpty)
        #expect(list.total == nil)
        #expect(!list.hasMore)
    }

    @Test func totalsAreOptional() async {
        let loader = GatedLoader(rows: 25, total: nil)
        let list = makeList(loader)
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        #expect(list.hasMore)
        list.loadMore()
        #expect(await waitFor { list.items.count == 20 })
        list.loadMore()
        #expect(await waitFor { list.items.count == 25 })
        #expect(list.total == nil)
        #expect(LibraryFormat.countLabel(list) == nil)
    }

    @Test func aPageOfNothingEndsPagingEvenWithANextOffset() async {
        let list = PagedList<TestRow>(pageSize: 10, loader: { _ in
            Page(items: [], offset: 0, total: nil, nextOffset: 10)
        })
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        #expect(!list.hasMore)
    }

    @Test func onFailureIsCalledForTheFirstAndLaterPages() async {
        let loader = GatedLoader()
        let list = makeList(loader)
        var errors: [MusicBackendError] = []
        list.onFailure = { if let error = $0 as? MusicBackendError { errors.append(error) } }
        loader.failNext(.unreachable("first"))
        list.reload()
        #expect(await waitFor { errors.count == 1 })
        list.reload()
        #expect(await waitFor { list.phase == .loaded })
        loader.failNext(.unreachable("later"))
        list.loadMoreIfNeeded(current: list.items[8])
        #expect(await waitFor { errors.count == 2 })
        #expect(errors == [.unreachable("first"), .unreachable("later")])
    }
}
