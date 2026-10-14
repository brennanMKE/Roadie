import Foundation
import MusicBackendKit
import MusicBackendStub
import os
@testable import LibraryBrowser

/// Polls until `condition` holds (up to `timeout` seconds). No fixed sleeps in the happy path.
@MainActor
func waitFor(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A model over a fresh stub, with a short search delay.
@MainActor
func makeModel(
    library: StubLibrary = .sample(),
    capabilities: BackendCapabilities = [.search, .artwork, .localOutput],
    delay: Duration = .milliseconds(20)
) -> (StubMusicBackend, LibraryBrowserModel) {
    let backend = StubMusicBackend(library: library, capabilities: capabilities)
    return (backend, LibraryBrowserModel(backend: backend, searchDelay: delay))
}

struct TestRow: Identifiable, Hashable, Sendable {
    var id: String
}

/// An in-process page loader: a request log, one-shot gates and failures, and a responder.
final class GatedLoader: @unchecked Sendable {
    private struct State {
        var requests: [PageRequest] = []
        var gateNext = false
        var failNext: MusicBackendError?
        var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var cancelled = 0
        var prefix = "r"
        var total: Int?
        var rows = 25
        var extra: [Int: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(rows: Int = 25, total: Int? = 25) {
        state.withLock { $0.rows = rows; $0.total = total }
    }

    var requests: [PageRequest] { state.withLock { $0.requests } }
    var cancelledCount: Int { state.withLock { $0.cancelled } }
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    func gateNext() { state.withLock { $0.gateNext = true } }
    func failNext(_ error: MusicBackendError) { state.withLock { $0.failNext = error } }
    func setPrefix(_ prefix: String) { state.withLock { $0.prefix = prefix } }
    /// The item at `index` is answered with this id instead of its own (to repeat an id across pages).
    func override(index: Int, id: String) { state.withLock { $0.extra[index] = id } }
    func setTotal(_ total: Int?) { state.withLock { $0.total = total } }

    func release() {
        let continuations = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            let all = Array(s.waiting.values)
            s.waiting = [:]
            return all
        }
        for continuation in continuations { continuation.resume() }
    }

    var loader: PagedList<TestRow>.Loader {
        { [self] request in try await respond(request) }
    }

    private func respond(_ request: PageRequest) async throws -> Page<TestRow> {
        enum Step { case fail(MusicBackendError), gate, answer }
        let (step, prefix) = state.withLock { s -> (Step, String) in
            s.requests.append(request)
            if let error = s.failNext {
                s.failNext = nil
                return (.fail(error), s.prefix)
            }
            if s.gateNext {
                s.gateNext = false
                return (.gate, s.prefix)
            }
            return (.answer, s.prefix)
        }
        switch step {
        case .fail(let error): throw error
        case .gate:
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let early = state.withLock { s -> Bool in
                        if Task.isCancelled { s.cancelled += 1; return true }
                        s.waiting[id] = continuation
                        return false
                    }
                    if early { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                    guard let c = s.waiting.removeValue(forKey: id) else { return nil }
                    s.cancelled += 1
                    return c
                }
                continuation?.resume(throwing: CancellationError())
            }
        case .answer: break
        }
        return state.withLock { s in
            let end = min(s.rows, request.offset + request.limit)
            let start = min(request.offset, end)
            let items = (start..<end).map { TestRow(id: s.extra[$0] ?? "\(prefix)\(String(format: "%02d", $0))") }
            return Page.make(items: items, request: request, total: s.total)
        }
    }
}

// MARK: Library sources

/// A flag a `@Sendable` `isConfigured` closure can read while a test flips it.
final class ConfiguredFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: true)
    var value: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

@MainActor
func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "LibraryBrowserTests-\(UUID().uuidString)")!
}

struct SourceFixture {
    var plex: StubMusicBackend
    var folder: StubMusicBackend
    var plexConfigured: ConfiguredFlag
    var folderConfigured: ConfiguredFlag
    var defaults: UserDefaults
    var controller: LibrarySourceController
    var suiteName: String

    /// Removes the private defaults suite.
    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
}

/// A controller over two stubs standing for Plex (25 artists) and the local folder (3 artists), with a private defaults suite.
@MainActor
func makeSources(stored: String? = nil, default defaultID: String = "plex") -> SourceFixture {
    let suiteName = "LibraryBrowserTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    if let stored { defaults.set(stored, forKey: LibrarySourceController.defaultsKey) }
    let plex = StubMusicBackend(library: .sample(artistCount: 25), sourceID: "plex", displayName: "Plex")
    let folder = StubMusicBackend(library: .sample(artistCount: 3), sourceID: "folder", displayName: "Local Folder")
    let plexFlag = ConfiguredFlag()
    let folderFlag = ConfiguredFlag()
    let controller = LibrarySourceController(
        sources: [
            LibrarySource(backend: plex, isConfigured: { plexFlag.value }),
            LibrarySource(backend: folder, isConfigured: { folderFlag.value }),
        ],
        defaultSourceID: defaultID, defaults: defaults, searchDelay: .milliseconds(20))
    return SourceFixture(
        plex: plex, folder: folder, plexConfigured: plexFlag, folderConfigured: folderFlag,
        defaults: defaults, controller: controller, suiteName: suiteName)
}

/// A playing snapshot with `title`.
func snapshot(title: String, on output: OutputDevice.ID = OutputDevice.thisMacID) -> NowPlaying {
    NowPlaying(output: output, state: .playing, title: title)
}
