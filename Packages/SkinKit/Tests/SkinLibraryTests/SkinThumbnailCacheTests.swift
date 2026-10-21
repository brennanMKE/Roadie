import CoreGraphics
import Foundation
import Testing

@testable import SkinKit
@testable import SkinLibrary

@Suite(.timeLimit(.minutes(1))) struct SkinThumbnailCacheTests {
    private func makeCache(
        _ dir: TempDir, renderer: CountingRenderer? = nil, version: Int = 1, concurrent: Int = 2,
        memoryCount: Int = 256, memoryBytes: Int = 48 << 20, diskLimit: Int64 = 1 << 30
    ) -> SkinThumbnailCache {
        if let renderer {
            return SkinThumbnailCache(
                directory: dir.appending("cache"), version: version, maxConcurrentRenders: concurrent,
                memoryLimitCount: memoryCount, memoryLimitBytes: memoryBytes, diskLimitBytes: diskLimit,
                sweepOnOpen: false, render: renderer.closure)
        }
        return SkinThumbnailCache(
            directory: dir.appending("cache"), version: version, maxConcurrentRenders: concurrent,
            memoryLimitCount: memoryCount, memoryLimitBytes: memoryBytes, diskLimitBytes: diskLimit, sweepOnOpen: false)
    }

    private func isMagenta(_ pixel: [UInt8]) -> Bool { pixel == [255, 0, 255, 255] }

    @Test func fileURLEncodesHashVersionAndSize() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let hash = String(repeating: "ab", count: 32)
        let cache = makeCache(dir)
        #expect(cache.fileURL(hash: hash) == dir.appending("cache/r1/\(hash)-275x116.png"))
        #expect(makeCache(dir, version: 7).fileURL(hash: hash) == dir.appending("cache/r7/\(hash)-275x116.png"))
        let skin = try fakeSkin(in: dir, "x")
        #expect(await cache.thumbnail(hash: "../../etc/passwd", url: skin.url) == nil)
        #expect(await cache.thumbnail(hash: String(repeating: "A", count: 64), url: skin.url) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending("cache/r1").path))
    }

    @Test func firstRequestRendersWritesAndReturns() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("skins/magenta.wsz")
        try SyntheticSkins.write(to: url, mainColor: (255, 0, 255))
        let hash = try SkinContentHash.hex(of: url)
        let cache = makeCache(dir)
        let thumbnail = try #require(await cache.thumbnail(hash: hash, url: url))
        #expect(thumbnail.image.width == 275 && thumbnail.image.height == 116)
        #expect(isMagenta(rgba(thumbnail.image, x: 4, y: 100)))
        let png = try #require(PNGWriter.read(cache.fileURL(hash: hash)))
        #expect(png.width == 275 && png.height == 116)
        #expect(isMagenta(rgba(png, x: 4, y: 100)))
        #expect(await cache.statistics.renders == 1)
    }

    @Test func secondRequestIsAMemoryHit() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let cache = makeCache(dir, renderer: renderer)
        let skin = try fakeSkin(in: dir, "a")
        #expect(await cache.thumbnail(hash: skin.hash, url: skin.url) != nil)
        #expect(await cache.thumbnail(hash: skin.hash, url: skin.url) != nil)
        let stats = await cache.statistics
        #expect(stats.memoryHits == 1)
        #expect(stats.renders == 1)
        #expect(renderer.started.count == 1)
        #expect(await cache.cached(hash: skin.hash) != nil)
    }

    @Test func freshInstanceReadsFromDisk() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("skins/magenta.wsz")
        try SyntheticSkins.write(to: url, mainColor: (255, 0, 255))
        let hash = try SkinContentHash.hex(of: url)
        #expect(await makeCache(dir).thumbnail(hash: hash, url: url) != nil)
        let second = makeCache(dir)
        let thumbnail = try #require(await second.thumbnail(hash: hash, url: url))
        let stats = await second.statistics
        #expect(stats.diskHits == 1)
        #expect(stats.renders == 0)
        #expect(isMagenta(rgba(thumbnail.image, x: 4, y: 100)))
    }

    @Test func concurrentRequestsShareOneRender() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let cache = makeCache(dir, renderer: renderer)
        let skin = try fakeSkin(in: dir, "shared")
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { await cache.thumbnail(hash: skin.hash, url: skin.url) != nil } }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 20 && !results.contains(false))
        #expect(await cache.statistics.renders == 1)
        #expect(renderer.started.count == 1)
    }

    @Test func rendersAreBoundedAndOffMain() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let latch = AsyncLatch()
        defer { latch.open() }
        let renderer = CountingRenderer(latch: latch)
        let cache = makeCache(dir, renderer: renderer, concurrent: 2)
        let skins = try (0..<12).map { try fakeSkin(in: dir, "s\($0)") }
        let tasks = skins.map { skin in Task { await cache.thumbnail(hash: skin.hash, url: skin.url) } }
        await waitUntil {
            let queued = await cache.statistics.queued
            return renderer.started.count == 2 && queued == 10
        }
        #expect(await cache.statistics.running == 2)
        latch.open()
        for task in tasks { #expect(await task.value != nil) }
        #expect(renderer.maxSimultaneous == 2)
        #expect(renderer.started.count == 12)
        #expect(!renderer.sawMainThread)
    }

    @Test func newestRequestRendersFirst() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let latch = AsyncLatch()
        defer { latch.open() }
        let renderer = CountingRenderer(latch: latch)
        let cache = makeCache(dir, renderer: renderer, concurrent: 1)
        let names = ["holder", "a", "b", "c"]
        let skins = try names.map { try fakeSkin(in: dir, $0) }
        var tasks: [Task<SkinThumbnail?, Never>] = []
        tasks.append(Task { await cache.thumbnail(hash: skins[0].hash, url: skins[0].url) })
        await waitUntil { renderer.started.count == 1 }
        for index in 1...3 {
            let skin = skins[index]
            tasks.append(Task { await cache.thumbnail(hash: skin.hash, url: skin.url) })
            await waitUntil { (await cache.statistics.queued) == index }
        }
        latch.open()
        for task in tasks { #expect(await task.value != nil) }
        #expect(renderer.started == ["holder.wsz", "c.wsz", "b.wsz", "a.wsz"])
    }

    @Test func cancelledBeforeStartIsDropped() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let latch = AsyncLatch()
        defer { latch.open() }
        let renderer = CountingRenderer(latch: latch)
        let cache = makeCache(dir, renderer: renderer, concurrent: 1)
        let x = try fakeSkin(in: dir, "x"), y = try fakeSkin(in: dir, "y")
        let holder = Task { await cache.thumbnail(hash: x.hash, url: x.url) }
        await waitUntil { renderer.started.count == 1 }
        let cancelled = Task { await cache.thumbnail(hash: y.hash, url: y.url) }
        await waitUntil { (await cache.statistics.queued) == 1 }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(await cache.statistics.dropped == 1)
        latch.open()
        #expect(await holder.value != nil)
        let stats = await cache.statistics
        #expect(stats.renders == 1)
        #expect(renderer.started == ["x.wsz"])
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(hash: y.hash).path))
    }

    @Test func cancelledAfterStartStillCaches() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let latch = AsyncLatch()
        defer { latch.open() }
        let renderer = CountingRenderer(latch: latch)
        let cache = makeCache(dir, renderer: renderer)
        let skin = try fakeSkin(in: dir, "late")
        let caller = Task { await cache.thumbnail(hash: skin.hash, url: skin.url) }
        await waitUntil { renderer.started.count == 1 }
        caller.cancel()
        // Give the cancellation hop a chance to run; the assertion below does not depend on it.
        await waitUntil { (await cache.waiterCount(hash: skin.hash)) == 0 }
        latch.open()
        _ = await caller.value
        #expect(await cache.thumbnail(hash: skin.hash, url: skin.url) != nil)
        let stats = await cache.statistics
        #expect(stats.renders == 1)
        #expect(stats.memoryHits == 1)
        #expect(stats.dropped == 0)
    }

    @Test func secondCallerKeepsAQueuedJobAlive() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let latch = AsyncLatch()
        defer { latch.open() }
        let renderer = CountingRenderer(latch: latch)
        let cache = makeCache(dir, renderer: renderer, concurrent: 1)
        let x = try fakeSkin(in: dir, "x"), shared = try fakeSkin(in: dir, "shared")
        let holder = Task { await cache.thumbnail(hash: x.hash, url: x.url) }
        await waitUntil { renderer.started.count == 1 }
        let first = Task { await cache.thumbnail(hash: shared.hash, url: shared.url) }
        await waitUntil { (await cache.waiterCount(hash: shared.hash)) == 1 }
        let second = Task { await cache.thumbnail(hash: shared.hash, url: shared.url) }
        await waitUntil { (await cache.waiterCount(hash: shared.hash)) == 2 }
        first.cancel()
        await waitUntil { (await cache.waiterCount(hash: shared.hash)) == 1 }
        latch.open()
        #expect(await second.value != nil)
        _ = await first.value
        _ = await holder.value
        #expect(await cache.statistics.dropped == 0)
    }

    @Test func failedSkinIsNegativeCachedInMemoryAndOnDisk() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("skins/modern.wsz")
        try SyntheticSkins.modern(to: url)
        let hash = try SkinContentHash.hex(of: url)
        let calls = Recorder<Int>()
        let counting: @Sendable (URL) throws(SkinError) -> CGImage = { (url: URL) throws(SkinError) -> CGImage in
            calls.add(1)
            return try SkinThumbnailCache.renderIdle(url)
        }
        let directory = dir.appending("cache")
        func open() -> SkinThumbnailCache {
            SkinThumbnailCache(directory: directory, sweepOnOpen: false, render: counting)
        }
        let cache = open()
        #expect(await cache.thumbnail(hash: hash, url: url) == nil)
        #expect(await cache.statistics.failures == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appending("cache/r\(SkinThumbnailCache.thumbnailVersion)/\(hash)-275x116.failed").path))
        #expect(await cache.thumbnail(hash: hash, url: url) == nil)
        #expect(await cache.statistics.failures == 1)
        #expect(calls.all.count == 1)
        #expect(await open().thumbnail(hash: hash, url: url) == nil)
        #expect(calls.all.count == 1)
    }

    @Test func garbageArchiveIsAFailureNotACrash() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("skins/garbage.wsz")
        try SyntheticSkins.garbage(to: url)
        let hash = try SkinContentHash.hex(of: url)
        let cache = makeCache(dir)
        #expect(await cache.thumbnail(hash: hash, url: url) == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending("cache/r1/\(hash)-275x116.failed").path))
    }

    @Test func missingFileReturnsNilWithoutMarker() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("skins/later.wsz")
        let hash = String(repeating: "1f", count: 32)
        let cache = makeCache(dir)
        #expect(await cache.thumbnail(hash: hash, url: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending("cache/r1/\(hash)-275x116.failed").path))
        try SyntheticSkins.write(to: url)
        #expect(await cache.thumbnail(hash: hash, url: url) != nil)
    }

    @Test func partialSkinStillRenders() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.appending("skins/partial.wsz")
        try SyntheticSkins.writeMainOnly(to: url)
        let hash = try SkinContentHash.hex(of: url)
        let cache = makeCache(dir)
        #expect(await cache.thumbnail(hash: hash, url: url) != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending("cache/r1/\(hash)-275x116.failed").path))
    }

    @Test func versionBumpDiscardsOldDirectory() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let a = try fakeSkin(in: dir, "a"), b = try fakeSkin(in: dir, "b")
        #expect(await makeCache(dir, renderer: renderer, version: 1).thumbnail(hash: a.hash, url: a.url) != nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending("cache/r1/\(a.hash)-275x116.png").path))
        let next = makeCache(dir, renderer: renderer, version: 2)
        #expect(await next.thumbnail(hash: b.hash, url: b.url) != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending("cache/r1").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending("cache/r2/\(b.hash)-275x116.png").path))
    }

    @Test func purgedDirectoryIsRecreated() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let cache = makeCache(dir, renderer: renderer)
        let a = try fakeSkin(in: dir, "a"), b = try fakeSkin(in: dir, "b")
        #expect(await cache.thumbnail(hash: a.hash, url: a.url) != nil)
        try FileManager.default.removeItem(at: dir.appending("cache"))
        #expect(await cache.thumbnail(hash: b.hash, url: b.url) != nil)
        #expect(FileManager.default.fileExists(atPath: cache.fileURL(hash: b.hash).path))
    }

    @Test func memoryEvictsByCountAndBytes() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let skins = try (0..<5).map { try fakeSkin(in: dir, "m\($0)") }
        let cache = makeCache(dir, renderer: renderer, concurrent: 1, memoryCount: 3)
        for skin in skins { #expect(await cache.thumbnail(hash: skin.hash, url: skin.url) != nil) }
        var stats = await cache.statistics
        #expect(stats.count == 3)
        #expect(stats.evictions == 2)
        for skin in skins.prefix(2) { #expect(await cache.thumbnail(hash: skin.hash, url: skin.url) != nil) }
        stats = await cache.statistics
        #expect(stats.diskHits == 2)
        #expect(stats.renders == 5)

        let small = makeCache(dir, renderer: renderer, concurrent: 1, memoryBytes: 200_000)
        for skin in skins.prefix(3) { #expect(await small.thumbnail(hash: skin.hash, url: skin.url) != nil) }
        #expect(await small.statistics.count == 1)
    }

    @Test func sweepTrimsDiskToSeventyFivePercent() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let skins = try (0..<8).map { try fakeSkin(in: dir, "w\($0)") }
        let probe = makeCache(dir, renderer: renderer)
        for skin in skins { #expect(await probe.thumbnail(hash: skin.hash, url: skin.url) != nil) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, skin) in skins.enumerated() { try touch(probe.fileURL(hash: skin.hash), mtime: base + Double(index)) }
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: probe.fileURL(hash: skins[0].hash).path)[.size] as? Int64)
        let marker = dir.appending("cache/r1/\(String(repeating: "0", count: 64))-275x116.failed")
        FileManager.default.createFile(atPath: marker.path, contents: nil)

        let cache = makeCache(dir, renderer: renderer, diskLimit: size * 4)
        await cache.sweep()
        let survivors = skins.map { FileManager.default.fileExists(atPath: cache.fileURL(hash: $0.hash).path) }
        #expect(survivors == [false, false, false, false, false, true, true, true])
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func clearForgetsMemoryAndNegatives() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let modern = dir.appending("skins/modern.wsz")
        try SyntheticSkins.modern(to: modern)
        let modernHash = try SkinContentHash.hex(of: modern)
        let calls = Recorder<Int>()
        let counting: @Sendable (URL) throws(SkinError) -> CGImage = { (url: URL) throws(SkinError) -> CGImage in
            calls.add(1)
            return try SkinThumbnailCache.renderIdle(url)
        }
        let cache = SkinThumbnailCache(directory: dir.appending("cache"), sweepOnOpen: false, render: counting)
        #expect(await cache.thumbnail(hash: modernHash, url: modern) == nil)
        let real = dir.appending("skins/real.wsz")
        try SyntheticSkins.write(to: real)
        let realHash = try SkinContentHash.hex(of: real)
        #expect(await cache.thumbnail(hash: realHash, url: real) != nil)
        let before = calls.all.count
        await cache.clear()
        #expect(await cache.statistics.count == 0)
        #expect(await cache.thumbnail(hash: modernHash, url: modern) == nil)
        #expect(await cache.thumbnail(hash: realHash, url: real) != nil)
        #expect(calls.all.count == before)
        #expect(await cache.statistics.diskHits == 1)
    }

    @Test func thumbnailForURLHashesFirst() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let original = dir.appending("skins/original.wsz"), copy = dir.appending("skins/copy.wsz")
        try SyntheticSkins.write(to: original)
        try FileManager.default.copyItem(at: original, to: copy)
        let hash = try SkinContentHash.hex(of: original)
        let cache = makeCache(dir)
        #expect(await cache.thumbnail(hash: hash, url: original) != nil)
        #expect(await cache.thumbnail(for: copy) != nil)
        let stats = await cache.statistics
        #expect(stats.memoryHits == 1)
        #expect(stats.renders == 1)
        #expect(await cache.thumbnail(for: dir.appending("skins/nothing.wsz")) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKIN_SAMPLES_DIR"] != nil))
    func sampleSkinsProduceThumbnails() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let root = URL(filePath: ProcessInfo.processInfo.environment["SKIN_SAMPLES_DIR"]!)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wsz" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!urls.isEmpty)
        let cache = makeCache(dir)
        let clock = ContinuousClock()
        var total = Duration.zero
        var expectFailures = 0
        for url in urls {
            let hash = try SkinContentHash.hex(of: url)
            let start = clock.now
            let thumbnail = await cache.thumbnail(hash: hash, url: url)
            let elapsed = clock.now - start
            total += elapsed
            if thumbnail == nil { expectFailures += 1 }
            print("thumb \(url.lastPathComponent) \(Int(elapsed / .milliseconds(1))) ms \(thumbnail == nil ? "none" : "ok")")
        }
        print("thumb total \(urls.count) skins \(total)")
        let first = await cache.statistics
        #expect(first.failures == expectFailures)
        for url in urls {
            _ = await cache.thumbnail(hash: try SkinContentHash.hex(of: url), url: url)
        }
        let second = await cache.statistics
        #expect(second.renders == first.renders)
    }

    @Test func removeForgetsMemoryAndDisk() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let renderer = CountingRenderer()
        let cache = makeCache(dir, renderer: renderer)
        let skin = try fakeSkin(in: dir, "a")
        #expect(await cache.thumbnail(hash: skin.hash, url: skin.url) != nil)
        #expect(FileManager.default.fileExists(atPath: cache.fileURL(hash: skin.hash).path))
        await cache.remove(hash: skin.hash)
        #expect(await cache.cached(hash: skin.hash) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(hash: skin.hash).path))
    }
}
