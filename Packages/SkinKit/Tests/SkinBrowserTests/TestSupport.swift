import CoreGraphics
import Foundation

@testable import SkinBrowser
@testable import SkinLibrary

/// Polls (5 ms steps, 5 s ceiling) instead of sleeping a fixed time on a happy path.
@MainActor
func waitFor(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

func record(
    _ id: Int64, _ name: String, status: SkinStatus = .ok, readme: String? = nil, path: String? = nil,
    fileCount: Int = 1
) -> SkinRecord {
    SkinRecord(
        id: id, hash: String(format: "%064llx", id), name: name, readme: readme, status: status,
        warnings: status == .ok ? [] : ["warning"], size: 10, fileCount: fileCount,
        primaryPath: path ?? "\(name).wsz")
}

struct StubFailure: LocalizedError {
    var errorDescription: String? { "stub failure" }
}

/// An in-memory index with recorded calls, error injection and a gate on `skins(matching:)`.
actor StubSkinIndex: SkinIndexReading {
    enum Call: Equatable {
        case counts
        case skins(SkinQuery)
        case count(SkinQuery)
        case neighbor(Int64, SkinNeighborDirection, Set<SkinStatus>)
        case skinAtPath(String)
        case random(Set<SkinStatus>)
    }

    private(set) var records: [SkinRecord]
    private(set) var calls: [Call] = []
    private var skinsError: Error?
    private var gated = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var cancelledCount = 0
    /// Extra folder-relative paths (a duplicate's other files) mapped to skin ids.
    private var extraPaths: [String: Int64] = [:]

    init(_ records: [SkinRecord]) { self.records = records }

    func setRecords(_ new: [SkinRecord]) { records = new }
    func setSkinsError(_ error: Error?) { skinsError = error }
    func addPath(_ path: String, for id: Int64) { extraPaths[path] = id }
    func gateSkins() { gated = true }
    func releaseSkins() {
        gated = false
        let pending = waiters
        waiters = [:]
        for (_, continuation) in pending { continuation.resume() }
    }
    var suspendedCount: Int { waiters.count }
    var skinsCalls: [SkinQuery] {
        calls.compactMap { if case .skins(let query) = $0 { query } else { nil } }
    }

    private func waitIfGated() async throws {
        guard gated else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cancelledCount += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        cancelledCount += 1
        continuation.resume(throwing: CancellationError())
    }

    private static func order(_ a: SkinRecord, _ b: SkinRecord) -> Bool {
        switch a.name.caseInsensitiveCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.id < b.id
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func matches(_ query: SkinQuery) -> [SkinRecord] {
        let wanted = query.hasText ? Self.words(query.text) : []
        return records.filter { query.statuses.contains($0.status) }.filter { record in
            let haystack = Self.words(record.name + " " + (record.readme ?? ""))
            return wanted.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
        }.sorted(by: Self.order)
    }

    func counts() async throws -> SkinIndexCounts {
        calls.append(.counts)
        var by: [SkinStatus: Int] = [:]
        for status in SkinStatus.allCases { by[status] = records.filter { $0.status == status }.count }
        return SkinIndexCounts(files: records.count, skins: records.count, byStatus: by)
    }

    func skins(matching query: SkinQuery) async throws -> [SkinRecord] {
        calls.append(.skins(query))
        try await waitIfGated()
        if let skinsError { throw skinsError }
        let all = matches(query)
        return Array(all.dropFirst(query.offset).prefix(query.limit))
    }

    func count(matching query: SkinQuery) async throws -> Int {
        calls.append(.count(query))
        return matches(query).count
    }

    func neighbor(of id: Int64, direction: SkinNeighborDirection, statuses: Set<SkinStatus>) async throws -> SkinRecord? {
        calls.append(.neighbor(id, direction, statuses))
        let ordered = records.filter { statuses.contains($0.status) }.sorted(by: Self.order)
        guard !ordered.isEmpty else { return nil }
        guard let index = records.first(where: { $0.id == id }).flatMap({ current in ordered.firstIndex { $0.id == current.id } })
        else {
            // The current skin is unknown (or not loadable): first for next, last for previous.
            if let current = records.first(where: { $0.id == id }) {
                let after = ordered.filter { Self.order(current, $0) }
                let before = ordered.filter { Self.order($0, current) }
                return direction == .next ? (after.first ?? ordered.first) : (before.last ?? ordered.last)
            }
            return direction == .next ? ordered.first : ordered.last
        }
        let step = direction == .next ? 1 : ordered.count - 1
        return ordered[(index + step) % ordered.count]
    }

    func skin(atPath path: String) async throws -> SkinRecord? {
        calls.append(.skinAtPath(path))
        if let id = extraPaths[path] { return records.first { $0.id == id } }
        return records.first { $0.primaryPath == path }
    }

    func randomSkin(statuses: Set<SkinStatus>) async throws -> SkinRecord? {
        calls.append(.random(statuses))
        return records.filter { statuses.contains($0.status) }.min(by: Self.order)
    }

    func skins(md5s: [String]) async throws -> [String: SkinRecord] {
        let wanted = Set(md5s)
        var result: [String: SkinRecord] = [:]
        for record in records { if let md5 = record.md5, wanted.contains(md5) { result[md5] = record } }
        return result
    }

    func skin(hash: String) async throws -> SkinRecord? {
        records.first { $0.hash == hash }
    }

    private(set) var removedPaths: [String] = []

    func removeFile(atPath path: String) async throws -> String? {
        removedPaths.append(path)
        if extraPaths.removeValue(forKey: path) != nil { return nil }
        guard let index = records.firstIndex(where: { $0.primaryPath == path }) else { return nil }
        return records.remove(at: index).hash
    }
}

/// Records what Move to Trash would have trashed; never touches the real Trash (#0131).
final class StubRemover: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var error: Error?
    var trashed: [URL] { lock.withLock { urls } }
    func fail(with error: Error?) { lock.withLock { self.error = error } }
    var closure: SkinBrowserModel.FileRemover {
        { [self] url in
            try lock.withLock {
                if let error { throw error }
                urls.append(url)
            }
        }
    }
}

@MainActor
final class RecordingApplier {
    private(set) var applied: [URL] = []
    private(set) var onMainActor: [Bool] = []
    func record(_ url: URL) {
        applied.append(url)
        onMainActor.append(Thread.isMainThread)
    }
}

final class StubThumbnails: SkinThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var requested: [URL] { lock.withLock { urls } }
    private var removedHashes: [String] = []
    var removed: [String] { lock.withLock { removedHashes } }

    func remove(hash: String) async { lock.withLock { removedHashes.append(hash) } }

    func thumbnail(for record: SkinRecord, at url: URL) async -> CGImage? {
        lock.withLock { urls.append(url) }
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }
}

let testFolder = URL(filePath: "/skins", directoryHint: .isDirectory)

@MainActor
func makeModel(
    _ records: [SkinRecord], folder: URL? = testFolder, pageSize: Int = 200, delay: Duration = .milliseconds(20),
    noIndex: Bool = false, remover: StubRemover = StubRemover()
) -> (StubSkinIndex, RecordingApplier, SkinBrowserModel, StubThumbnails) {
    let stub = StubSkinIndex(records)
    let applier = RecordingApplier()
    let thumbs = StubThumbnails()
    let model = SkinBrowserModel(
        index: { noIndex ? nil : stub }, folder: { folder }, thumbnails: thumbs,
        applySkin: { applier.record($0) }, removeFile: remover.closure, pageSize: pageSize, prefetchDistance: 40, searchDelay: delay)
    return (stub, applier, model, thumbs)
}

func numbered(_ count: Int, status: SkinStatus = .ok) -> [SkinRecord] {
    (1...count).map { record(Int64($0), String(format: "skin%04d", $0), status: status) }
}
