import Foundation
import os

private let log = Logger(subsystem: "co.sstools.roadie", category: "SkinLibrary")

/// Runs the incremental pass over a skins folder: scan, compare with the stamps in the store, hash the changed
/// files, parse only hashes the store has not seen, and apply the results in batches.
public actor SkinIndexer {
    private let folder: URL
    private let store: SkinIndexStore
    private let ingester: any SkinIngesting
    private let parserVersion: Int
    private let concurrency: Int
    private let batchSize: Int
    private let progressInterval: Duration
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var running = false

    public init(
        folder: URL, store: SkinIndexStore, ingester: any SkinIngesting = SkinIngester(),
        parserVersion: Int = SkinIngester.parserVersion,
        concurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        batchSize: Int = 64, progressInterval: Duration = .milliseconds(250)
    ) {
        self.folder = folder
        self.store = store
        self.ingester = ingester
        self.parserVersion = parserVersion
        self.concurrency = max(1, concurrency)
        self.batchSize = max(1, batchSize)
        self.progressInterval = progressInterval
    }

    public var isRunning: Bool { running }

    /// Stops the pass at the next batch boundary; batches already committed stay. Callable from anywhere.
    public nonisolated func cancel() { cancelFlag.withLock { $0 = true } }

    /// One pass. `full` ignores the stamps and hashes every file; only changed hashes are parsed again.
    public func run(
        full: Bool = false, progress: (@Sendable (SkinIndexProgress) -> Void)? = nil
    ) async throws -> SkinIndexSummary {
        guard !running else { throw SkinLibraryError.passAlreadyRunning }
        running = true
        cancelFlag.withLock { $0 = false }
        defer { running = false }

        let clock = ContinuousClock()
        let started = clock.now
        var lastEmit: ContinuousClock.Instant?
        func emit(_ value: SkinIndexProgress, force: Bool = false) {
            guard let progress else { return }
            if !force, let last = lastEmit, last.duration(to: clock.now) < progressInterval { return }
            lastEmit = clock.now
            progress(value)
        }

        var summary = SkinIndexSummary()
        emit(SkinIndexProgress(phase: .scanning), force: true)

        let folder = self.folder
        let onDisk = try await Task.detached(priority: .utility) { try FolderScanner.list(folder: folder) }.value
        let known = try await store.fileStamps()
        let diskPaths = Set(onDisk.map(\.path))
        let version = parserVersion
        let changed = onDisk.filter { stamp in
            guard !full, let existing = known[stamp.path] else { return true }
            return existing.stamp != stamp || existing.parserVersion < version
        }
        let missing = known.keys.filter { !diskPaths.contains($0) }.sorted()
        summary.totalFiles = onDisk.count
        summary.unchanged = onDisk.count - changed.count
        summary.removed = try await store.removeFiles(missing)

        var state = SkinIndexProgress(phase: .indexing, changed: changed.count, processed: 0, totalFiles: onDisk.count)
        emit(state, force: true)

        var start = 0
        while start < changed.count {
            if cancelFlag.withLock({ $0 }) || Task.isCancelled {
                summary.cancelled = true
                break
            }
            let batch = Array(changed[start..<min(start + batchSize, changed.count)])
            let (counts, failed) = try await ingest(batch)
            summary.added += counts.added
            summary.updated += counts.updated
            summary.linked += counts.linked
            summary.failed += failed
            start += batch.count
            state.processed = start
            emit(state)
            log.debug("indexed batch, \(start, privacy: .public) of \(changed.count, privacy: .public)")
        }

        emit(SkinIndexProgress(phase: .pruning, changed: changed.count, processed: state.processed, totalFiles: onDisk.count), force: true)
        try await store.pruneOrphans()
        if !summary.cancelled {
            summary.cancelled = try await backfillMD5 { processed in
                emit(SkinIndexProgress(phase: .hashing, changed: changed.count, processed: processed, totalFiles: onDisk.count))
            }
        }
        let formatter = ISO8601DateFormatter()
        try await store.setMeta("last_scan", formatter.string(from: Date()))
        try await store.setMeta("folder", folder.path)
        await store.checkpoint()
        summary.totalSkins = try await store.counts().skins
        summary.duration = started.duration(to: clock.now).seconds
        try await store.setMeta(
            "last_summary",
            "files \(summary.totalFiles), skins \(summary.totalSkins), added \(summary.added), updated \(summary.updated), "
                + "linked \(summary.linked), removed \(summary.removed), failed \(summary.failed)"
                + (summary.cancelled ? ", cancelled" : ""))
        emit(SkinIndexProgress(phase: .done, changed: changed.count, processed: state.processed, totalFiles: onDisk.count), force: true)
        log.info(
            "pass finished: \(summary.totalFiles, privacy: .public) files, \(summary.added, privacy: .public) added, \(summary.updated, privacy: .public) updated, \(summary.linked, privacy: .public) linked, \(summary.removed, privacy: .public) removed, \(summary.failed, privacy: .public) failed, cancelled \(summary.cancelled, privacy: .public)"
        )
        return summary
    }

    // MARK: Single-file add (#0126)

    /// Indexes just these folder-relative paths (a skin the Museum downloaded) without walking the folder.
    /// Throws `.passAlreadyRunning` while `run` is active; the caller queues a normal pass instead.
    public func add(paths: [String]) async throws -> SkinIndexSummary {
        guard !running else { throw SkinLibraryError.passAlreadyRunning }
        running = true
        defer { running = false }
        let clock = ContinuousClock()
        let started = clock.now
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var stamps: [FileStamp] = []
        for path in Set(paths) {
            let values = try folder.appending(path: path).resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { throw SkinLibraryError.folderUnreadable("not a file: \(path)") }
            stamps.append(
                FileStamp(
                    path: path, size: Int64(values.fileSize ?? 0),
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        stamps.sort { $0.path < $1.path }
        var summary = SkinIndexSummary()
        var start = 0
        while start < stamps.count {
            let batch = Array(stamps[start..<min(start + batchSize, stamps.count)])
            let (counts, failed) = try await ingest(batch)
            summary.added += counts.added
            summary.updated += counts.updated
            summary.linked += counts.linked
            summary.failed += failed
            start += batch.count
        }
        summary.totalFiles = try await store.counts().files
        summary.totalSkins = try await store.counts().skins
        summary.duration = started.duration(to: clock.now).seconds
        log.info("added \(stamps.count, privacy: .public) files without a pass")
        return summary
    }

    // MARK: MD5 backfill (#0126)

    /// Computes the MD5 of skins indexed before schema v2 (hash only, no ZIP parse), in cancellable batches.
    /// Returns whether it was cancelled. A file whose bytes no longer match the stored hash is left for the next pass.
    private func backfillMD5(progress: (Int) -> Void) async throws -> Bool {
        let folder = self.folder
        let ingester = self.ingester
        var after: Int64 = 0
        var processed = 0
        while true {
            if cancelFlag.withLock({ $0 }) || Task.isCancelled { return true }
            let rows = try await store.skinsMissingMD5(after: after, limit: batchSize)
            guard let last = rows.last else { return false }
            after = last.id
            let results: [(id: Int64, md5: String)?] = await Self.boundedMap(rows, concurrency: concurrency) { row in
                guard let digests = try? ingester.digests(folder.appending(path: row.path)) else { return (row.id, "") }
                return digests.sha256 == row.hash ? (row.id, digests.md5) : nil
            }
            try await store.setMD5s(results.compactMap { $0 })
            processed += rows.count
            progress(processed)
        }
    }

    // MARK: One batch

    private struct Hashed: Sendable {
        var stamp: FileStamp
        var hash: String
        var md5: String
        var failure: String?
    }

    private func ingest(_ batch: [FileStamp]) async throws -> (AppliedCounts, Int) {
        let folder = self.folder
        let ingester = self.ingester
        let hashed: [Hashed] = await Self.boundedMap(batch, concurrency: concurrency) { stamp in
            let url = folder.appending(path: stamp.path)
            do {
                let digests = try ingester.digests(url)
                return Hashed(stamp: stamp, hash: digests.sha256, md5: digests.md5, failure: nil)
            } catch {
                // A stable key that cannot collide with real content, so the row is not retried until the stamp changes.
                let key = SkinContentHash.hex(of: Data("unreadable:\(stamp.path)".utf8))
                return Hashed(stamp: stamp, hash: key, md5: "", failure: "Unreadable file: \(error.localizedDescription)")
            }
        }

        let knownIDs = try await store.knownSkinIDs(forHashes: Array(Set(hashed.map(\.hash))), parserVersion: parserVersion)
        // The first path (batch is path-ordered) of each unknown hash is parsed; the rest link to it.
        var firstForHash: [String: Hashed] = [:]
        var order: [Hashed] = []
        for item in hashed where knownIDs[item.hash] == nil && firstForHash[item.hash] == nil {
            firstForHash[item.hash] = item
            order.append(item)
        }
        let inspections: [SkinInspection] = await Self.boundedMap(order, concurrency: concurrency) { item in
            if let failure = item.failure { return SkinInspection(readme: nil, status: .failed, warnings: [failure]) }
            return ingester.inspect(folder.appending(path: item.stamp.path))
        }
        var inspectionByHash: [String: SkinInspection] = [:]
        for (item, inspection) in zip(order, inspections) { inspectionByHash[item.hash] = inspection }

        var outcomes: [IngestOutcome] = []
        var failed = 0
        for item in hashed {
            if let inspection = inspectionByHash[item.hash] {
                if inspection.status == .failed { failed += 1 }
                if firstForHash[item.hash]?.stamp.path == item.stamp.path {
                    let name = URL(filePath: item.stamp.path).deletingPathExtension().lastPathComponent
                    outcomes.append(
                        .parsed(
                            stamp: item.stamp, hash: item.hash, name: name, readme: inspection.readme,
                            status: inspection.status, warnings: inspection.warnings, parserVersion: parserVersion,
                            md5: item.md5))
                    continue
                }
            }
            outcomes.append(.linked(stamp: item.stamp, hash: item.hash, md5: item.md5))
        }
        return (try await store.apply(outcomes), failed)
    }

    /// Maps `items` with at most `concurrency` running at once; results keep the input order.
    static func boundedMap<T: Sendable, R: Sendable>(
        _ items: [T], concurrency: Int, _ work: @escaping @Sendable (T) -> R
    ) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(concurrency, items.count) {
                let index = next, item = items[next]
                group.addTask { (index, work(item)) }
                next += 1
            }
            while let (index, value) = await group.next() {
                results[index] = value
                if next < items.count {
                    let nextIndex = next, item = items[next]
                    group.addTask { (nextIndex, work(item)) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
