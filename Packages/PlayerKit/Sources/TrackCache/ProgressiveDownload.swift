import AudioCore
import Foundation

/// The bytes on disk so far for one in-flight download, and how it ended. Written by the download task,
/// read by progressive readers on their own threads.
final class DownloadProgress: @unchecked Sendable {
    private let condition = NSCondition()
    private var frontier: Int64 = 0
    private var outcome: Result<Void, any Error>?
    private var isCancelled = false

    var bytesOnDisk: Int64 {
        condition.lock()
        defer { condition.unlock() }
        return frontier
    }

    var finished: Result<Void, any Error>? {
        condition.lock()
        defer { condition.unlock() }
        return outcome
    }

    func advance(to bytes: Int64) {
        condition.lock()
        frontier = max(frontier, bytes)
        condition.broadcast()
        condition.unlock()
    }

    /// Completes the download. Called after the file has been verified and indexed.
    func finish(with result: Result<Void, any Error>) {
        condition.lock()
        if outcome == nil {
            outcome = result
            if case .success = result { frontier = .max }
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Wakes waiters with `.cancelled`.
    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(through end: Int64, timeout: TimeInterval) -> ProgressiveWaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if frontier >= end { return .available }
            if let outcome {
                switch outcome {
                case .success: return .available
                case .failure(let error): return error is CancellationError ? .cancelled : .failed(error)
                }
            }
            if isCancelled { return .cancelled }
            if !condition.wait(until: deadline) { return .timedOut }
        }
    }
}

/// A Plex part that is still downloading, as the player reads it (#0039). It registers as a holder on the
/// cache's in-flight download, so the download survives while the player listens and is abandoned when the
/// player lets go (unless something else needs it). It reads the temporary file through its own descriptor,
/// opened up front: the inode survives the move into `Tracks/` after verification, and even an unlink on
/// failure, so a read never races the cache. Holds no token, URL or request; `description` is the key.
public final class ProgressiveDownload: ProgressiveByteSource, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable, @unchecked Sendable {
    public enum State: Sendable {
        case downloading
        case completed
        case failed(any Error)
    }

    private let cache: TrackCache
    private let key: String
    private let holder: UUID
    private let progress: DownloadProgress
    private let downloader: any CacheDownloader
    private let partKey: String
    private let lock = NSLock()
    private var descriptor: Int32
    private var closed = false

    public let finalSize: Int64
    public let pathExtension: String

    init?(
        cache: TrackCache, key: String, holder: UUID, progress: DownloadProgress, tempURL: URL, finalSize: Int64,
        pathExtension: String, downloader: any CacheDownloader, partKey: String
    ) {
        let descriptor = Darwin.open(tempURL.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        self.cache = cache
        self.key = key
        self.holder = holder
        self.progress = progress
        self.descriptor = descriptor
        self.finalSize = finalSize
        self.pathExtension = pathExtension
        self.downloader = downloader
        self.partKey = partKey
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    public var description: String { "ProgressiveDownload(\(key))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public var state: State {
        switch progress.finished {
        case .none: .downloading
        case .success: .completed
        case .failure(let error): .failed(error)
        }
    }

    public var availableBytes: Int64 { min(progress.bytesOnDisk, finalSize) }

    public func waitForBytes(through end: Int64, timeout: TimeInterval) -> ProgressiveWaitOutcome {
        if isClosedOrCancelled { return .cancelled }
        let outcome = progress.wait(through: min(end, finalSize), timeout: timeout)
        if case .timedOut = outcome, isClosedOrCancelled { return .cancelled }
        return outcome
    }

    public func read(into buffer: UnsafeMutableRawPointer, offset: Int64, count: Int) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        var total = 0
        while total < count {
            let got = pread(descriptor, buffer + total, count - total, off_t(offset) + off_t(total))
            if got < 0 {
                if errno == EINTR { continue }
                throw TrackCacheError.io("could not read the download")
            }
            if got == 0 { break }
            total += got
        }
        return total
    }

    /// Bridges to the downloader's async range request. The caller is the reader's own thread, never a
    /// Swift task, so blocking here is fine; the wait polls so a cancel is noticed.
    public func fetchRange(_ range: Range<Int64>) throws -> Data {
        final class Box: @unchecked Sendable {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, any Error>?
        }
        let box = Box()
        let downloader = self.downloader
        let partKey = self.partKey
        let task = Task.detached {
            do { box.result = .success(try await downloader.fetch(partKey: partKey, range: range)) } catch {
                box.result = .failure(error)
            }
            box.semaphore.signal()
        }
        while box.semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if isClosedOrCancelled {
                task.cancel()
                throw CancellationError()
            }
        }
        switch box.result {
        case .success(let data): return data
        case .failure(let error): throw TrackCache.map(error)
        case .none: throw CancellationError()
        }
    }

    private var isClosedOrCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || cancelled
    }

    private var cancelled = false

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func close() {
        lock.lock()
        let first = !closed
        closed = true
        if first, descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        lock.unlock()
        guard first else { return }
        let cache = self.cache, key = self.key, holder = self.holder
        Task { await cache.release(key: key, holder: holder) }
    }
}
