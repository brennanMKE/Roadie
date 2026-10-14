import Foundation
import os
import Testing
@testable import TrackCache

/// A scratch directory under the system temp dir; never the real Caches folder.
func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrackCacheTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

/// A settable clock for the cache's `now` closure.
final class ManualClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { lock.withLock { $0 } }
    func advance(seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Polls until `condition` holds (up to `timeout` seconds). No fixed sleeps in the happy path.
func waitFor(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// File names to sizes, excluding `tmp/` and `index.json`.
func filesOnDisk(_ dir: URL) -> [String: Int64] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    var result: [String: Int64] = [:]
    for name in names where name != "tmp" && name != "index.json" {
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
        result[name] = size ?? -1
    }
    return result
}

func tempContents(_ dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tmp").path)) ?? []
}

/// Reads every file under `dir` as bytes and searches for the UTF-8 of `text`.
func directoryContains(_ dir: URL, _ text: String) -> Bool {
    let needle = Data(text.utf8)
    guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let data = try? Data(contentsOf: url) else { continue }
        if data.range(of: needle) != nil { return true }
    }
    return false
}

/// An in-process downloader: a table of bodies, call counts, and per-part gates that suspend a
/// download until the test releases or fails it.
final class StubDownloader: CacheDownloader, @unchecked Sendable {
    private struct State {
        var bodies: [String: Data] = [:]
        var calls: [String: Int] = [:]
        var gated: Set<String> = []
        var waiting: [UUID: (partKey: String, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var cancelledEarly: Set<UUID> = []
        var cancelCount = 0
        /// Trickle mode: parts that write one chunk per permit.
        var trickleChunk: [String: Int] = [:]
        var permits: [String: Int] = [:]
        var released: [String: Int] = [:]
        var permitWaiters: [UUID: (partKey: String, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var rangeCalls: [RangeCall] = []
    }

    struct RangeCall: Equatable, Sendable {
        let partKey: String
        let range: Range<Int64>
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setBody(_ data: Data, for partKey: String) { state.withLock { $0.bodies[partKey] = data } }
    func gate(_ partKey: String) { state.withLock { _ = $0.gated.insert(partKey) } }

    /// Writes `partKey` in chunks of `chunkSize`, one chunk per `releaseChunks` permit, reporting progress after each.
    func trickle(_ partKey: String, chunkSize: Int) { state.withLock { $0.trickleChunk[partKey] = chunkSize } }

    func releaseChunks(_ partKey: String, count: Int) {
        let toResume = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.permits[partKey, default: 0] += count
            var resumed: [CheckedContinuation<Void, any Error>] = []
            for (id, waiter) in state.permitWaiters where waiter.partKey == partKey && (state.permits[partKey] ?? 0) > 0 {
                state.permits[partKey, default: 0] -= 1
                state.released[partKey, default: 0] += 1
                state.permitWaiters[id] = nil
                resumed.append(waiter.continuation)
            }
            return resumed
        }
        for continuation in toResume { continuation.resume() }
    }

    /// Chunks the trickle has written (or is allowed to).
    func releasedChunks(_ partKey: String) -> Int { state.withLock { $0.released[partKey] ?? 0 } }

    var rangeCalls: [RangeCall] { state.withLock { $0.rangeCalls } }

    func fetch(partKey: String, range: Range<Int64>) async throws -> Data {
        let body = state.withLock { state -> Data? in
            state.rangeCalls.append(RangeCall(partKey: partKey, range: range))
            return state.bodies[partKey]
        }
        guard let body, Int(range.upperBound) <= body.count else { throw TrackCacheError.download(.notFound) }
        return body.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    func calls(_ partKey: String) -> Int { state.withLock { $0.calls[partKey] ?? 0 } }
    var totalCalls: Int { state.withLock { $0.calls.values.reduce(0, +) } }
    var cancelCount: Int { state.withLock { $0.cancelCount } }

    /// Lets every suspended download for `partKey` continue, and ungates it.
    func release(_ partKey: String) {
        let toResume = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.gated.remove(partKey)
            let ids = state.waiting.filter { $0.value.partKey == partKey }.map(\.key)
            return ids.compactMap { state.waiting.removeValue(forKey: $0)?.continuation }
        }
        for continuation in toResume { continuation.resume() }
    }

    /// Fails every suspended download for `partKey`, and ungates it.
    func fail(_ partKey: String, with error: any Error) {
        let toResume = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.gated.remove(partKey)
            let ids = state.waiting.filter { $0.value.partKey == partKey }.map(\.key)
            return ids.compactMap { state.waiting.removeValue(forKey: $0)?.continuation }
        }
        for continuation in toResume { continuation.resume(throwing: error) }
    }

    func download(partKey: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let isGated = state.withLock { state -> Bool in
            state.calls[partKey, default: 0] += 1
            return state.gated.contains(partKey)
        }
        if isGated {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let early = state.withLock { state -> Bool in
                        if state.cancelledEarly.remove(id) != nil { return true }
                        state.waiting[id] = (partKey, continuation)
                        return false
                    }
                    if early { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                    state.cancelCount += 1
                    guard let waiter = state.waiting.removeValue(forKey: id) else {
                        state.cancelledEarly.insert(id)
                        return nil
                    }
                    return waiter.continuation
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
        let body = state.withLock { $0.bodies[partKey] } ?? Data(repeating: 7, count: 100)
        if let chunk = state.withLock({ $0.trickleChunk[partKey] }) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            var offset = 0
            while offset < body.count {
                try await waitForPermit(partKey)
                try Task.checkCancellation()
                let end = min(offset + chunk, body.count)
                try handle.write(contentsOf: body.subdata(in: offset..<end))
                offset = end
                progress(Int64(offset))
            }
            return Int64(body.count)
        }
        try body.write(to: fileURL)
        progress(Int64(body.count))
        return Int64(body.count)
    }

    /// Suspends until the test grants a chunk; cancellation resumes it with `CancellationError`.
    private func waitForPermit(_ partKey: String) async throws {
        enum Registration { case granted, cancelled, parked }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> Registration in
                    if state.cancelledEarly.remove(id) != nil { return .cancelled }
                    if (state.permits[partKey] ?? 0) > 0 {
                        state.permits[partKey, default: 0] -= 1
                        state.released[partKey, default: 0] += 1
                        return .granted
                    }
                    state.permitWaiters[id] = (partKey, continuation)
                    return .parked
                }
                switch registration {
                case .granted: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.cancelCount += 1
                guard let waiter = state.permitWaiters.removeValue(forKey: id) else {
                    state.cancelledEarly.insert(id)
                    return nil
                }
                return waiter.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// One cache over a temp directory with a stub downloader and a manual clock.
struct Harness {
    let dir: URL
    let clock = ManualClock()
    let stub = StubDownloader()
    let cache: TrackCache

    init(limit: Int64 = TrackCache.defaultLimitBytes, dir: URL = makeTempDir()) {
        self.dir = dir
        let clock = self.clock
        cache = TrackCache(directory: dir, limitBytes: limit, downloader: stub, now: { clock.now })
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    static func partKey(_ key: String) -> String { "/library/parts/\(key)/file.m4a" }

    /// A second cache over the same directory (a relaunch).
    func reopen(limit: Int64 = TrackCache.defaultLimitBytes) -> TrackCache {
        let clock = self.clock
        return TrackCache(directory: dir, limitBytes: limit, downloader: stub, now: { clock.now })
    }

    @discardableResult
    func get(_ key: String, bytes: Int? = nil, expected: Int64? = nil, cache override: TrackCache? = nil) async throws -> URL {
        if let bytes { stub.setBody(randomBytes(bytes), for: Self.partKey(key)) }
        return try await (override ?? cache).file(forKey: key, partKey: Self.partKey(key), expectedSize: expected)
    }
}
