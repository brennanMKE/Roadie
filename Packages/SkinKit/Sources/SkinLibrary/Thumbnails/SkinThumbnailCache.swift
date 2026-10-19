import CoreGraphics
import Foundation
import os
import SkinKit

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "SkinThumbnails")

/// One main-window thumbnail. `CGImage` is immutable; wrapped like `Skin` is.
public struct SkinThumbnail: @unchecked Sendable {
    /// 275x116, RGBA8 (decoded from the PNG on a disk hit).
    public let image: CGImage
    public var byteCount: Int { image.bytesPerRow * image.height }
}

/// Lazy main-window thumbnails keyed by the skin's content hash (`SkinContentHash`), cached in memory and as PNGs
/// under `~/Library/Caches/<bundle id>/SkinThumbnails/r<version>/`. Nothing is rendered until someone asks; requests
/// are served newest first with a bounded number of renders at once, always off the calling thread.
public actor SkinThumbnailCache {
    /// Bump when `MainWindowRenderer.render(state: .idle)` pixels change (renderer, layout, idle preset, parser
    /// fallbacks, visualizer colours). Old `r*` directories are deleted on first use.
    public static let thumbnailVersion = 2
    public static let size = CGSize(width: 275, height: 116)

    public struct Statistics: Hashable, Sendable {
        public var memoryHits = 0, diskHits = 0, renders = 0, failures = 0
        /// Cancelled before their render started.
        public var dropped = 0
        public var evictions = 0, count = 0, bytes = 0, queued = 0, running = 0
    }

    /// `~/Library/Caches/<bundle id>/SkinThumbnails`
    public static func defaultDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: bundleIdentifier ?? "com.brennanmke.SkinAmp", directoryHint: .isDirectory)
            .appending(path: "SkinThumbnails", directoryHint: .isDirectory)
    }

    /// Parses the skin and draws its idle main window at 1x, clipped to the skin's shape.
    public static func renderIdle(_ url: URL) throws(SkinError) -> CGImage {
        let skin = try SkinParser.parse(url: url)
        return MainWindowRenderer.render(skin: skin, state: .idle, scale: 1, clipToRegion: true)
    }

    private enum Outcome: Sendable {
        case disk(SkinThumbnail), rendered(SkinThumbnail), failed, knownFailure, missing
    }

    private struct Job {
        let task: Task<SkinThumbnail?, Never>
        var waiters = 1
        var started = false
    }

    private let store: ThumbnailStore
    private let gate: RenderQueue
    private let render: @Sendable (URL) async throws(SkinError) -> CGImage
    private let memoryLimitCount: Int
    private let memoryLimitBytes: Int
    private let diskLimitBytes: Int64
    private let sweepOnOpen: Bool
    private var prepared = false
    private var sequence: UInt64 = 0
    private var entries: [String: SkinThumbnail] = [:]
    private var order: [String] = []  // least recently used first
    private var bytes = 0
    private var negative: Set<String> = []
    private var inFlight: [String: (id: UInt64, job: Job)] = [:]
    private var stats = Statistics()
    private static let negativeLimit = 10_000

    /// `render` is injectable for tests and may suspend; the default never does. `sweepOnOpen` trims the disk in the background on first use.
    public init(
        directory: URL,
        version: Int = thumbnailVersion,
        maxConcurrentRenders: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        memoryLimitCount: Int = 256,
        memoryLimitBytes: Int = 48 << 20,
        diskLimitBytes: Int64 = 1 << 30,
        sweepOnOpen: Bool = true,
        render: @escaping @Sendable (URL) async throws(SkinError) -> CGImage = SkinThumbnailCache.renderIdle
    ) {
        store = ThumbnailStore(root: directory, version: version)
        gate = RenderQueue(limit: maxConcurrentRenders)
        self.render = render
        self.memoryLimitCount = max(1, memoryLimitCount)
        self.memoryLimitBytes = memoryLimitBytes
        self.diskLimitBytes = diskLimitBytes
        self.sweepOnOpen = sweepOnOpen
    }

    public nonisolated func fileURL(hash: String) -> URL { store.url(for: hash) }

    public var statistics: Statistics {
        var copy = stats
        copy.count = entries.count
        copy.bytes = bytes
        let counts = gate.counts
        copy.queued = counts.queued
        copy.running = counts.running
        return copy
    }

    /// Callers waiting on the in-flight job for `hash` (tests synchronize on it).
    func waiterCount(hash: String) -> Int { inFlight[hash]?.job.waiters ?? 0 }

    /// Memory only: no I/O, does not touch the LRU.
    public func cached(hash: String) -> SkinThumbnail? { entries[hash] }

    /// The thumbnail for the skin at `url` whose content hash is `hash` (`SkinRecord.hash`). nil means: show the
    /// placeholder (failed, missing, invalid hash). Never throws.
    public func thumbnail(hash: String, url: URL) async -> SkinThumbnail? {
        guard SkinContentHash.isValid(hash) else { return nil }
        prepareIfNeeded()
        if let hit = touch(hash) {
            stats.memoryHits += 1
            return hit
        }
        if negative.contains(hash) { return nil }
        let id: UInt64
        let task: Task<SkinThumbnail?, Never>
        // A job whose last caller just cancelled it is on its way out (its `jobDropped` hop may not have run yet):
        // joining it would return nil, so start a fresh one. The stale job's bookkeeping is keyed by id and ignored.
        if var existing = inFlight[hash], !existing.job.task.isCancelled {
            existing.job.waiters += 1
            inFlight[hash] = existing
            id = existing.id
            task = existing.job.task
        } else {
            sequence += 1
            id = sequence
            task = startJob(hash: hash, url: url, id: id)
            inFlight[hash] = (id, Job(task: task))
        }
        // The caller waits for the job even when cancelled; a job nobody wants that has not started is dropped, so
        // the wait is short. The handler is synchronous and hops back into the actor.
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.callerCancelled(hash: hash, id: id) }
        }
    }

    /// Hashes the file first, for callers without an index row (drag-and-drop, the current skin).
    public func thumbnail(for url: URL) async -> SkinThumbnail? {
        let hash = await Task.detached(priority: .userInitiated) { try? SkinContentHash.hex(of: url) }.value
        guard let hash else { return nil }
        return await thumbnail(hash: hash, url: url)
    }

    /// Forgets memory and the in-memory failures; disk is untouched.
    public func clear() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
        negative.removeAll()
    }

    /// Memory and disk (Settings, Reset).
    public func removeAll() throws {
        clear()
        prepared = false
        try store.removeAll()
    }

    /// Trims the disk to 75 % of `diskLimitBytes` when over it, oldest files first.
    public func sweep() async {
        let store = store, limit = diskLimitBytes
        let result = await Task.detached(priority: .utility) { store.sweep(limitBytes: limit) }.value
        if result.removed > 0 {
            log.info("sweep removed \(result.removed, privacy: .public) thumbnails, \(result.remaining, privacy: .public) bytes left")
        }
    }

    // MARK: Jobs

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        let removed = store.prepare()
        if removed > 0 { log.info("removed \(removed, privacy: .public) old thumbnail directories") }
        if sweepOnOpen { Task(priority: .utility) { await self.sweep() } }
    }

    private func startJob(hash: String, url: URL, id: UInt64) -> Task<SkinThumbnail?, Never> {
        let store = store, gate = gate, render = render
        return Task.detached(priority: .userInitiated) {
            do {
                try await gate.acquire(id: id)
            } catch {
                await self.jobDropped(hash: hash, id: id)
                return nil
            }
            await self.jobStarted(hash: hash, id: id)
            let outcome = await Self.produce(hash: hash, url: url, store: store, render: render)
            gate.release()
            return await self.jobFinished(hash: hash, id: id, outcome: outcome)
        }
    }

    /// The only place pixels are made or files are read: runs on a worker, never on the actor.
    private nonisolated static func produce(
        hash: String, url: URL, store: ThumbnailStore, render: @Sendable (URL) async throws(SkinError) -> CGImage
    ) async -> Outcome {
        if let image = store.readPNG(hash) { return .disk(SkinThumbnail(image: image)) }
        if store.hasFailedMarker(hash) { return .knownFailure }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let image = try await render(url)
            if let data = PNGWriter.data(image) {
                do {
                    try store.write(data, hash: hash)
                } catch {
                    log.error("thumbnail write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            log.debug("rendered \(hash.prefix(8), privacy: .public)")
            return .rendered(SkinThumbnail(image: image))
        } catch {
            store.writeFailedMarker(hash)
            return .failed
        }
    }

    private func jobStarted(hash: String, id: UInt64) {
        guard var entry = inFlight[hash], entry.id == id else { return }
        entry.job.started = true
        inFlight[hash] = entry
    }

    private func jobDropped(hash: String, id: UInt64) {
        guard let entry = inFlight[hash], entry.id == id else { return }
        inFlight[hash] = nil
        stats.dropped += 1
    }

    private func jobFinished(hash: String, id: UInt64, outcome: Outcome) -> SkinThumbnail? {
        if let entry = inFlight[hash], entry.id == id { inFlight[hash] = nil }
        switch outcome {
        case .disk(let thumbnail):
            stats.diskHits += 1
            insert(thumbnail, hash: hash)
            return thumbnail
        case .rendered(let thumbnail):
            stats.renders += 1
            insert(thumbnail, hash: hash)
            return thumbnail
        case .failed:
            stats.failures += 1
            remember(failed: hash)
            return nil
        case .knownFailure:
            remember(failed: hash)
            return nil
        case .missing:
            return nil
        }
    }

    private func callerCancelled(hash: String, id: UInt64) {
        guard var entry = inFlight[hash], entry.id == id else { return }
        entry.job.waiters -= 1
        inFlight[hash] = entry
        if entry.job.waiters <= 0, !entry.job.started { entry.job.task.cancel() }
    }

    // MARK: Memory

    private func remember(failed hash: String) {
        if negative.count >= Self.negativeLimit { negative.removeAll() }
        negative.insert(hash)
    }

    private func touch(_ hash: String) -> SkinThumbnail? {
        guard let thumbnail = entries[hash] else { return nil }
        if let index = order.firstIndex(of: hash) { order.remove(at: index) }
        order.append(hash)
        return thumbnail
    }

    private func insert(_ thumbnail: SkinThumbnail, hash: String) {
        if let old = entries[hash] {
            bytes -= old.byteCount
            if let index = order.firstIndex(of: hash) { order.remove(at: index) }
        }
        entries[hash] = thumbnail
        order.append(hash)
        bytes += thumbnail.byteCount
        while entries.count > memoryLimitCount || (bytes > memoryLimitBytes && entries.count > 1) {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { bytes -= removed.byteCount }
            stats.evictions += 1
        }
    }
}
