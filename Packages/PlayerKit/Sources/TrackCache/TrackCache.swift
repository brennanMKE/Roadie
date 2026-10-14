import AudioCore
import Foundation
import PlexKit
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "TrackCache")

/// Writes one part into a file the cache created. Must honour task cancellation (throw
/// `CancellationError` or `URLError(.cancelled)`); the cache deletes the file either way.
public protocol CacheDownloader: Sendable {
    /// Returns the number of bytes written. `progress` is called with the bytes on disk so far after every
    /// flush and once at the end; a progressive reader reads the file up to that point.
    func download(partKey: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64
    /// `Range: bytes=lo-hi`. 206 is the body; 200 (the server ignored the range) is the slice; 401, 404 and
    /// other statuses are the same `TrackCacheError.download` cases as `download`.
    func fetch(partKey: String, range: Range<Int64>) async throws -> Data
}

/// What `TrackCache.open` hands back: the finished file, or a download still arriving.
public enum CachedFile: Sendable {
    case ready(URL)
    case downloading(ProgressiveDownload)
}

public enum TrackCacheError: Error, Hashable, Sendable, LocalizedError {
    case notPlexTrack
    /// No saved address or no token.
    case noServer
    /// The key's machineIdentifier is not the saved server's.
    case serverMismatch
    /// 401, 404, other status, transport.
    case download(PlexError)
    case sizeMismatch(expected: Int64?, actual: Int64)
    /// A FileManager / FileHandle failure, its localizedDescription.
    case io(String)

    /// Short English per case. None interpolates a URL, a request or a header; the Player shows
    /// these as its `errorMessage`.
    public var errorDescription: String? {
        switch self {
        case .notPlexTrack: "This track has no file on the Plex server."
        case .noServer: "Plex is not set up. Add the server address and sign in under Settings."
        case .serverMismatch: "This track belongs to a different Plex server than the one in Settings."
        case .download(let error): error.errorDescription
        case .sizeMismatch: "The download was incomplete."
        case .io(let detail): "The track could not be saved to the cache (\(detail))."
        }
    }
}

extension TrackCacheError: SourceScopedError {
    /// Whole source: nothing in the queue will fare better until Settings or the server change.
    public var affectsWholeSource: Bool {
        switch self {
        case .noServer, .serverMismatch, .io: true
        case .download(.transport), .download(.unauthorized), .download(.invalidBaseURL): true
        case .notPlexTrack, .sizeMismatch, .download: false
        }
    }
}

/// A bounded on-disk cache of downloaded files with least-recently-used eviction. It knows keys,
/// file names, sizes, dates and pins, and gets bytes from a `CacheDownloader`; it never sees a
/// request, a client or a token.
public actor TrackCache {
    public struct Entry: Codable, Hashable, Sendable {
        public var key: String
        /// "<key>.<ext>"
        public var fileName: String
        public var size: Int64
        public var lastAccess: Date

        public init(key: String, fileName: String, size: Int64, lastAccess: Date) {
            self.key = key
            self.fileName = fileName
            self.size = size
            self.lastAccess = lastAccess
        }
    }

    public struct Stats: Hashable, Sendable {
        public var totalBytes: Int64
        public var fileCount: Int
        public var limitBytes: Int64
        public var inFlight: Int
    }

    public static let defaultLimitBytes: Int64 = 2_000_000_000
    public static let indexFileName = "index.json"
    public static let tempDirectoryName = "tmp"

    /// ~/Library/Caches/<bundle id>/Tracks
    public static func defaultDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(bundleIdentifier ?? "com.brennanmke.SkinAmp", isDirectory: true)
            .appendingPathComponent("Tracks", isDirectory: true)
    }

    private struct Index: Codable {
        var version: Int
        var entries: [Entry]
    }

    /// One download and everyone waiting on it. Only touched from the actor.
    private final class Inflight {
        let id = UUID()
        let tempURL: URL
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
        /// Progressive readers that keep the download alive until they close.
        var holders: Set<UUID> = []
        let progress = DownloadProgress()
        init(tempURL: URL) { self.tempURL = tempURL }
    }

    public private(set) var pinned: Set<String> = []
    public private(set) var limitBytes: Int64

    private let directory: URL
    private let downloader: any CacheDownloader
    private let now: @Sendable () -> Date
    private var entriesByKey: [String: Entry] = [:]
    private var inflight: [String: Inflight] = [:]
    private var prepared = false

    public init(
        directory: URL,
        limitBytes: Int64 = TrackCache.defaultLimitBytes,
        downloader: any CacheDownloader,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.downloader = downloader
        self.now = now
    }

    private var tempDirectory: URL { directory.appendingPathComponent(Self.tempDirectoryName, isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }

    // MARK: Lifecycle

    /// Creates the directories, wipes tmp/, loads or rebuilds the index, reconciles it with the
    /// files on disk, evicts to the limit. Idempotent; every other method calls it first.
    public func prepare() throws {
        guard !prepared else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tempDirectory.path) { try fm.removeItem(at: tempDirectory) }
            try createDirectories()
        } catch {
            throw TrackCacheError.io(error.localizedDescription)
        }

        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let index = try? Self.decoder.decode(Index.self, from: data) {
            for entry in index.entries { loaded[entry.key] = entry }
        }

        // Reconcile with what is actually on disk.
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])) ?? []
        var onDisk: [String: (url: URL, size: Int64, modified: Date)] = [:]
        for url in urls {
            let name = url.lastPathComponent
            if name == Self.indexFileName || name == Self.tempDirectoryName { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            onDisk[name] = (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? now())
        }
        var result: [String: Entry] = [:]
        var claimed: Set<String> = []
        for (key, entry) in loaded {
            guard let file = onDisk[entry.fileName] else { continue }   // file gone: drop the entry
            if file.size != entry.size {
                try? fm.removeItem(at: file.url)                        // corrupt: drop both
                claimed.insert(entry.fileName)
                continue
            }
            result[key] = entry
            claimed.insert(entry.fileName)
        }
        for (name, file) in onDisk where !claimed.contains(name) {
            let key = (name as NSString).deletingPathExtension
            result[key] = Entry(key: key, fileName: name, size: file.size, lastAccess: file.modified)
        }
        entriesByKey = result
        prepared = true
        evictIfNeeded(protecting: [])
        writeIndex()
        log.debug("prepared: \(result.count) files, \(self.totalBytes) bytes")
    }

    /// Creates `Tracks/` and `tmp/` if they are missing. Safe to call while downloads are in flight.
    private func createDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    private func ensurePrepared() throws {
        if !prepared { try prepare() }
    }

    // MARK: Lookup and download

    /// The cached file for `key`, downloading it through `partKey` when it is not on disk.
    /// A hit touches `lastAccess`. Concurrent calls for one key share one download.
    public func file(forKey key: String, partKey: String, expectedSize: Int64?) async throws -> URL {
        try Task.checkCancellation()
        try ensurePrepared()
        if let url = hit(key) { return url }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                do {
                    let download = try inflight[key] ?? startDownload(key: key, partKey: partKey, expectedSize: expectedSize)
                    download.waiters[waiterID] = continuation
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.leave(key: key, waiter: waiterID) }
        }
    }

    /// Like `file(forKey:)`, but a miss returns as soon as the download starts, as a `ProgressiveDownload` the
    /// player reads while the bytes arrive. Needs `expectedSize`; without it the download is awaited in full.
    /// The download is verified and indexed exactly as before: the index only learns a key in `insert`.
    public func open(forKey key: String, partKey: String, expectedSize: Int64?) async throws -> CachedFile {
        try Task.checkCancellation()
        try ensurePrepared()
        if let url = hit(key) { return .ready(url) }
        guard let expectedSize, expectedSize > 0 else {
            return .ready(try await file(forKey: key, partKey: partKey, expectedSize: expectedSize))
        }
        let download = try inflight[key] ?? startDownload(key: key, partKey: partKey, expectedSize: expectedSize)
        let holder = UUID()
        guard let reader = ProgressiveDownload(
            cache: self, key: key, holder: holder, progress: download.progress, tempURL: download.tempURL,
            finalSize: expectedSize, pathExtension: (Self.fileName(key: key, partKey: partKey) as NSString).pathExtension,
            downloader: downloader, partKey: partKey) else {
            if download.waiters.isEmpty && download.holders.isEmpty && !pinned.contains(key) { abandon(key, download) }
            throw TrackCacheError.io("could not open the download")
        }
        download.holders.insert(holder)
        return .downloading(reader)
    }

    /// A progressive reader closed. The download goes with it unless someone else still needs it.
    func release(key: String, holder: UUID) {
        guard let download = inflight[key], download.holders.remove(holder) != nil else { return }
        if download.waiters.isEmpty && download.holders.isEmpty && !pinned.contains(key) { abandon(key, download) }
    }

    private func hit(_ key: String) -> URL? {
        guard var entry = entriesByKey[key] else { return nil }
        let url = directory.appendingPathComponent(entry.fileName)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard let size, size == entry.size else {
            // Purged or corrupt: forget it and download again.
            try? FileManager.default.removeItem(at: url)
            entriesByKey[key] = nil
            writeIndex()
            log.debug("stale \(key, privacy: .public)")
            return nil
        }
        entry.lastAccess = now()
        entriesByKey[key] = entry
        writeIndex()
        log.debug("hit \(key, privacy: .public) \(size) bytes")
        return url
    }

    private func startDownload(key: String, partKey: String, expectedSize: Int64?) throws -> Inflight {
        let tempURL = tempDirectory.appendingPathComponent("\(key)-\(UUID().uuidString).part")
        var created = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        if !created && !FileManager.default.fileExists(atPath: tempDirectory.path) {
            // Caches was purged, or Tracks/ deleted, while the app runs: put the folders back and retry once.
            do { try createDirectories() } catch { throw TrackCacheError.io(error.localizedDescription) }
            let before = entriesByKey.count
            entriesByKey = entriesByKey.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path) }
            log.info("cache folders were missing; recreated them and dropped \(before - self.entriesByKey.count) entries")
            created = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        }
        guard created else { throw TrackCacheError.io("could not create a temporary file") }
        let download = Inflight(tempURL: tempURL)
        inflight[key] = download
        let downloader = self.downloader
        let progress = download.progress
        download.task = Task {
            let outcome: Result<Int64, any Error>
            do {
                outcome = .success(try await downloader.download(partKey: partKey, to: tempURL, progress: { progress.advance(to: $0) }))
            } catch {
                outcome = .failure(error)
            }
            self.finish(key: key, download: download, partKey: partKey, expectedSize: expectedSize, outcome: outcome)
        }
        log.debug("miss \(key, privacy: .public)")
        return download
    }

    private func finish(key: String, download: Inflight, partKey: String, expectedSize: Int64?, outcome: Result<Int64, any Error>) {
        let fm = FileManager.default
        let isCurrent = inflight[key] === download
        let result: Result<URL, any Error>
        switch outcome {
        case .success:
            result = insert(key: key, partKey: partKey, tempURL: download.tempURL, expectedSize: expectedSize)
        case .failure(let error):
            try? fm.removeItem(at: download.tempURL)
            let mapped = Self.map(error)
            if !(mapped is CancellationError) {
                log.error("download failed \(key, privacy: .public): \(String(describing: type(of: mapped)), privacy: .public)")
            }
            result = .failure(mapped)
        }
        if isCurrent { inflight[key] = nil }
        // After `insert`: a reader that sees the download complete can rely on the file being verified and indexed.
        download.progress.finish(with: result.map { _ in () })
        let waiters = download.waiters
        download.waiters = [:]
        for continuation in waiters.values { continuation.resume(with: result) }
    }

    private func insert(key: String, partKey: String, tempURL: URL, expectedSize: Int64?) -> Result<URL, any Error> {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size == 0 || (expectedSize != nil && expectedSize != size) {
            try? fm.removeItem(at: tempURL)
            log.error("size mismatch \(key, privacy: .public): expected \(expectedSize ?? -1), got \(size)")
            return .failure(TrackCacheError.sizeMismatch(expected: expectedSize, actual: size))
        }
        let fileName = Self.fileName(key: key, partKey: partKey)
        let destination = directory.appendingPathComponent(fileName)
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            try? fm.removeItem(at: tempURL)
            return .failure(TrackCacheError.io(error.localizedDescription))
        }
        entriesByKey[key] = Entry(key: key, fileName: fileName, size: size, lastAccess: now())
        log.debug("insert \(key, privacy: .public) \(size) bytes")
        evictIfNeeded(protecting: [key])
        writeIndex()
        return .success(destination)
    }

    private func leave(key: String, waiter: UUID) {
        // An unknown waiter was already answered: the download finished, failed, or was abandoned
        // before this cancel reached the actor. Nothing to do.
        guard let download = inflight[key], let continuation = download.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if download.waiters.isEmpty && download.holders.isEmpty && !pinned.contains(key) { abandon(key, download) }
    }

    /// Cancels a download nobody is waiting for. Its entry goes at once so a request that arrives a
    /// moment later starts a fresh download instead of inheriting a cancelled one.
    private func abandon(_ key: String, _ download: Inflight) {
        download.task?.cancel()
        download.progress.cancel()
        try? FileManager.default.removeItem(at: download.tempURL)
        if inflight[key] === download { inflight[key] = nil }
        log.debug("cancelled \(key, privacy: .public)")
    }

    static func map(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: return error
        case let error as TrackCacheError: return error
        case let error as PlexError: return TrackCacheError.download(error)
        case let error as URLError:
            return error.code == .cancelled ? CancellationError() : TrackCacheError.download(.transport(error.code))
        default: return TrackCacheError.io(error.localizedDescription)
        }
    }

    static func fileName(key: String, partKey: String) -> String {
        let raw = (partKey as NSString).pathExtension.lowercased()
        let valid = !raw.isEmpty && raw.count <= 5 && raw.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
        return key + "." + (valid ? raw : "audio")
    }

    // MARK: Pins, limit, eviction

    public func setPinned(_ keys: Set<String>) {
        pinned = keys
        // A pinned download may run with no waiters; once unpinned it has no reason to continue.
        for (key, download) in inflight where download.waiters.isEmpty && download.holders.isEmpty && !keys.contains(key) {
            abandon(key, download)
        }
    }

    /// Persists nothing; evicts at once.
    public func setLimit(_ bytes: Int64) {
        limitBytes = bytes
        guard (try? ensurePrepared()) != nil else { return }
        let before = entriesByKey.count
        evictIfNeeded(protecting: [])
        if entriesByKey.count != before { writeIndex() }
    }

    private var totalBytes: Int64 { entriesByKey.values.reduce(0) { $0 + $1.size } }

    private func evictIfNeeded(protecting: Set<String>) {
        let keep = pinned.union(protecting).union(inflight.keys)
        while totalBytes > limitBytes {
            let candidate = entriesByKey.values
                .filter { !keep.contains($0.key) }
                .min { ($0.lastAccess, $0.key) < ($1.lastAccess, $1.key) }
            guard let victim = candidate else {
                log.info("over the limit but nothing can be evicted")
                return
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(victim.fileName))
            entriesByKey[victim.key] = nil
            log.debug("evict \(victim.key, privacy: .public) \(victim.size) bytes")
        }
    }

    // MARK: Inspection

    public func stats() -> Stats {
        try? ensurePrepared()
        return Stats(totalBytes: totalBytes, fileCount: entriesByKey.count, limitBytes: limitBytes, inFlight: inflight.count)
    }

    /// Oldest first.
    public func entries() -> [Entry] {
        try? ensurePrepared()
        return entriesByKey.values.sorted { ($0.lastAccess, $0.key) < ($1.lastAccess, $1.key) }
    }

    /// Removes every file and the index. Downloads in flight finish normally. Files held open by an
    /// `AVAudioFile` keep playing (the inode stays until it is closed).
    public func clear() throws {
        try ensurePrepared()
        let fm = FileManager.default
        var failure: String?
        for entry in entriesByKey.values {
            do { try fm.removeItem(at: directory.appendingPathComponent(entry.fileName)) } catch {
                if fm.fileExists(atPath: directory.appendingPathComponent(entry.fileName).path) { failure = error.localizedDescription }
            }
        }
        entriesByKey = [:]
        try? fm.removeItem(at: indexURL)
        if let failure { throw TrackCacheError.io(failure) }
    }

    // MARK: Index

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private func writeIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let index = Index(version: 1, entries: entriesByKey.values.sorted { $0.key < $1.key })
        do {
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            log.error("could not write the index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
