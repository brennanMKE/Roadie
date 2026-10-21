import Foundation
import Testing

@testable import SkinMuseum

@Suite struct MuseumResultCacheTests {
    private let page = MuseumPage(
        skins: [
            MuseumSkin(
                md5: md5(1), filename: "a_[S1].wsz", screenshotURL: screenshotURL(md5(1)),
                downloadURL: URL(string: "https://r2.webampskins.org/skins/\(md5(1)).wsz")!,
                museumURL: URL(string: "https://skins.webamp.org/skin/\(md5(1))")!, nsfw: nil)
        ], total: 1, hasMore: false)

    private func key(_ n: Int) -> String { MuseumQuery.browse(offset: n * 60, first: 60, includeNSFW: false).cacheKey }

    @Test func freshPageIsReturnedWithoutStaleFlag() async throws {
        let clock = TestClock()
        let cache = MuseumResultCache(directory: try makeTempDirectory(), now: { clock.now })
        await cache.store(page, for: key(0))
        clock.advance(60)
        let cached = try #require(await cache.page(for: key(0)))
        #expect(cached.page == page)
        #expect(!cached.isStale)
    }

    @Test func pageOlderThanTTLIsStale() async throws {
        let clock = TestClock()
        let cache = MuseumResultCache(directory: try makeTempDirectory(), now: { clock.now })
        await cache.store(page, for: key(0))
        clock.advance(MuseumResultCache.defaultTTL + 1)
        let cached = try #require(await cache.page(for: key(0)))
        #expect(cached.page == page)
        #expect(cached.isStale)
    }

    @Test func entryCapEvictsOldest() async throws {
        let clock = TestClock()
        let cache = MuseumResultCache(directory: try makeTempDirectory(), maxEntries: 2, now: { clock.now })
        for n in 0..<3 {
            clock.advance(10)
            await cache.store(page, for: key(n))
        }
        #expect(await cache.page(for: key(0)) == nil)
        #expect(await cache.page(for: key(1)) != nil)
        #expect(await cache.page(for: key(2)) != nil)
    }

    @Test func offlineFallsBackToCachedPage() async throws {
        let transport = StubMuseumTransport(.fixture("search-zelda"), .failure(.notConnectedToInternet))
        let client = MuseumClient(
            transport: transport, userAgent: "test",
            resultCache: MuseumResultCache(directory: try makeTempDirectory()), sleep: { _ in })
        let query = MuseumQuery.search(text: "zelda", offset: 0, first: 60, includeNSFW: false)
        #expect(await client.cachedPage(query) == nil)
        let live = try await client.page(query)
        await #expect(throws: MuseumError.offline) { try await client.page(query) }
        let cached = try #require(await client.cachedPage(query))
        #expect(cached.page == live)
        #expect(cached.page.skins.count == 3)
        #expect(!cached.isStale)
    }
}
