import Foundation
import MusicBackendKit
import MusicBackendStub
import Testing
@testable import MusicLibraryKit

@Suite struct ArtworkCacheTests {
    private func makeBackend(_ refs: [ArtworkRef] = [ref(1)], png: Data = pngData(width: 64, height: 64)) async -> StubMusicBackend {
        let backend = StubMusicBackend()
        for ref in refs { await backend.setArtwork(png, for: ref) }
        return backend
    }

    @Test func fetchesOnceAndServesFromMemory() async {
        let backend = await makeBackend()
        let cache = ArtworkCache(backend: backend)
        let first = await cache.image(for: ref(1))
        let second = await cache.image(for: ref(1))
        #expect(first != nil && second != nil)
        let stats = await cache.statistics
        #expect(stats.fetches == 1)
        #expect(stats.hits == 1)
        #expect(stats.misses == 1)
        #expect(stats.count == 1)
        #expect(stats.bytes > 0)
        #expect(await backend.count(.artwork) == 1)
    }

    @Test func concurrentRequestsCoalesce() async {
        let backend = await makeBackend()
        await backend.gate(.artwork)
        let cache = ArtworkCache(backend: backend)
        let tasks = (0..<10).map { _ in Task { await cache.image(for: ref(1)) } }
        #expect(await waitFor { await backend.suspendedCount == 1 })
        await backend.release(.artwork)
        for task in tasks { #expect(await task.value != nil) }
        #expect(await cache.statistics.fetches == 1)
        #expect(await backend.count(.artwork) == 1)
    }

    @Test func decodesToAtMostMaxPixels() async {
        let backend = await makeBackend(png: pngData(width: 600, height: 600))
        let cache = ArtworkCache(backend: backend, maxPixels: 200)
        let artwork = await cache.image(for: ref(1))
        #expect(artwork?.pixelWidth == 200)
        #expect(artwork?.pixelHeight == 200)
        #expect(await backend.calls(.artwork) == [.artwork(ref(1), 200)])
    }

    @Test func aNonSquareImageKeepsItsAspect() async {
        let backend = await makeBackend(png: pngData(width: 600, height: 300))
        let cache = ArtworkCache(backend: backend)
        let artwork = await cache.image(for: ref(1))
        #expect(artwork?.pixelWidth == 200)
        #expect(artwork?.pixelHeight == 100)
    }

    @Test func missingArtworkIsRememberedAsPlaceholder() async {
        let backend = await makeBackend()
        await backend.setError(.notFound(MediaID(.album, "1")), for: .artwork)
        let cache = ArtworkCache(backend: backend)
        #expect(await cache.image(for: ref(1)) == nil)
        #expect(await cache.image(for: ref(1)) == nil)
        #expect(await cache.statistics.fetches == 1)
    }

    @Test func undecodableBytesBecomeAPlaceholder() async {
        let backend = await makeBackend(png: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]))
        let cache = ArtworkCache(backend: backend)
        #expect(await cache.image(for: ref(1)) == nil)
        #expect(await cache.image(for: ref(1)) == nil)
        #expect(await cache.statistics.fetches == 1)
    }

    @Test func transportFailuresAreRetried() async {
        let backend = await makeBackend()
        await backend.setError(.unreachable("down"), for: .artwork)
        let cache = ArtworkCache(backend: backend)
        #expect(await cache.image(for: ref(1)) == nil)
        await backend.setError(nil, for: .artwork)
        #expect(await cache.image(for: ref(1)) != nil)
        #expect(await cache.statistics.fetches == 2)
    }

    @Test func evictsTheLeastRecentlyUsedImage() async {
        let refs = [ref(1), ref(2), ref(3), ref(4)]
        let backend = await makeBackend(refs)
        // Size the budget from a probe so it holds three images and a bit more.
        let probe = ArtworkCache(backend: backend)
        let size = await probe.image(for: ref(1))?.byteCount ?? 1
        let cache = ArtworkCache(backend: backend, limitBytes: size * 3 + size / 2)
        _ = await cache.image(for: ref(1))
        _ = await cache.image(for: ref(2))
        _ = await cache.image(for: ref(3))
        _ = await cache.image(for: ref(1))  // touch A
        _ = await cache.image(for: ref(4))
        #expect(await cache.cached(ref(2)) == nil)
        #expect(await cache.cached(ref(1)) != nil)
        #expect(await cache.cached(ref(4)) != nil)
        let stats = await cache.statistics
        #expect(stats.evictions == 1)
        #expect(stats.bytes <= size * 3 + size / 2)
    }

    @Test func countLimitAppliesToo() async {
        let refs = [ref(1), ref(2), ref(3)]
        let backend = await makeBackend(refs)
        let cache = ArtworkCache(backend: backend, limitCount: 2)
        for ref in refs { _ = await cache.image(for: ref) }
        #expect(await cache.statistics.count == 2)
        #expect(await cache.cached(ref(1)) == nil)
    }

    @Test func cancelledWaiterDoesNotCancelTheFetch() async {
        let backend = await makeBackend()
        await backend.gate(.artwork)
        let cache = ArtworkCache(backend: backend)
        let task = Task { await cache.image(for: ref(1)) }
        #expect(await waitFor { await backend.suspendedCount == 1 })
        task.cancel()
        await backend.release(.artwork)
        _ = await task.value
        #expect(await waitFor { await cache.cached(ref(1)) != nil })
        #expect(await cache.statistics.fetches == 1)
        #expect(await backend.cancelledCount == 0)
    }

    @Test func clearEmptiesEverything() async {
        let backend = await makeBackend([ref(1), ref(2)])
        let cache = ArtworkCache(backend: backend)
        _ = await cache.image(for: ref(1))
        await backend.setError(.notFound(MediaID(.album, "2")), for: .artwork)
        _ = await cache.image(for: ref(2))
        await backend.setError(nil, for: .artwork)
        await cache.clear()
        let stats = await cache.statistics
        #expect(stats.count == 0 && stats.bytes == 0)
        _ = await cache.image(for: ref(1))
        _ = await cache.image(for: ref(2))
        #expect(await cache.statistics.fetches == 4)
    }

    @Test func descriptionsNeverCarryRefsOrErrors() async {
        let backend = await makeBackend()
        let cache = ArtworkCache(backend: backend)
        _ = await cache.image(for: ref(1))
        let text = String(describing: await cache.statistics)
        #expect(!text.contains("library/metadata"))
    }
}
