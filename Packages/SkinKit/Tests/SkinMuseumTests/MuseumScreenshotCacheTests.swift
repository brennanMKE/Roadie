import Foundation
import Testing

@testable import SkinMuseum

@Suite struct MuseumScreenshotCacheTests {
    private func makeCache(_ dir: URL, _ transport: ScreenshotTransport, clock: TestClock = TestClock(),
                       maxDiskBytes: Int = 1_000_000, maxMemoryEntries: Int = 300) -> MuseumScreenshotCache {
        MuseumScreenshotCache(
            directory: dir, transport: transport, userAgent: "test", maxDiskBytes: maxDiskBytes,
            maxMemoryEntries: maxMemoryEntries, now: { clock.now })
    }

    @Test func secondRequestIsServedFromDisk() async throws {
        let dir = try makeTempDirectory()
        let transport = ScreenshotTransport()
        let first = try await makeCache(dir, transport).screenshot(md5: md5(1), url: screenshotURL(md5(1)))
        // A fresh cache (empty memory) must read the disk copy.
        let second = try await makeCache(dir, transport).screenshot(md5: md5(1), url: screenshotURL(md5(1)))
        #expect(first == second)
        #expect(transport.totalCalls == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(md5(1)).png").path))
    }

    @Test func concurrentRequestsForOneMD5FetchOnce() async throws {
        let transport = ScreenshotTransport(delay: .milliseconds(200))
        let cache = makeCache(try makeTempDirectory(), transport)
        let url = screenshotURL(md5(2))
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<5 { group.addTask { try await cache.screenshot(md5: md5(2), url: url) } }
            for try await data in group { #expect(data.count == 10) }
        }
        #expect(transport.totalCalls == 1)
    }

    @Test func diskCapEvictsLeastRecentlyUsed() async throws {
        let dir = try makeTempDirectory()
        let clock = TestClock()
        let transport = ScreenshotTransport(bytes: 10)
        let cache = makeCache(dir, transport, clock: clock, maxDiskBytes: 25)
        for n in 1...2 {
            clock.advance(10)
            _ = try await cache.screenshot(md5: md5(n), url: screenshotURL(md5(n)))
        }
        clock.advance(10)
        _ = try await cache.screenshot(md5: md5(1), url: screenshotURL(md5(1)))  // 1 is now newer than 2.
        clock.advance(10)
        _ = try await cache.screenshot(md5: md5(3), url: screenshotURL(md5(3)))
        let exists = { (n: Int) in FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(md5(n)).png").path) }
        #expect(exists(1))
        #expect(!exists(2))
        #expect(exists(3))
        #expect(transport.totalCalls == 3)
    }

    @Test func invalidMD5NeverBecomesAPath() async throws {
        let dir = try makeTempDirectory()
        let transport = ScreenshotTransport()
        let cache = makeCache(dir, transport)
        for bad in ["../../etc/passwd", "ABCDEF0123456789ABCDEF0123456789", "abc", ""] {
            #expect(await cache.fileURL(for: bad) == nil)
            await #expect(throws: MuseumError.self) {
                try await cache.screenshot(md5: bad, url: screenshotURL(md5(1)))
            }
        }
        #expect(transport.totalCalls == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func failedFetchIsNotCached() async throws {
        let dir = try makeTempDirectory()
        let failing = ScreenshotTransport(failure: .notConnectedToInternet)
        let cache = makeCache(dir, failing)
        await #expect(throws: MuseumError.offline) {
            try await cache.screenshot(md5: md5(4), url: screenshotURL(md5(4)))
        }
        await #expect(throws: MuseumError.offline) {
            try await cache.screenshot(md5: md5(4), url: screenshotURL(md5(4)))
        }
        #expect(failing.totalCalls == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
