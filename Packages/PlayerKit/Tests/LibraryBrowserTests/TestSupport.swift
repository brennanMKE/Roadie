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
    var server: StubMusicBackend
    var folder: StubMusicBackend
    var serverConfigured: ConfiguredFlag
    var folderConfigured: ConfiguredFlag
    var defaults: UserDefaults
    var controller: LibrarySourceController
    var suiteName: String

    /// Removes the private defaults suite.
    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
}

/// A controller over two stubs standing for Server (25 artists) and the local folder (3 artists), with a private defaults suite.
@MainActor
func makeSources(
    stored: String? = nil, default defaultID: String = "server", folderProbe: SourceProbe? = nil
) -> SourceFixture {
    let suiteName = "LibraryBrowserTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    if let stored { defaults.set(stored, forKey: LibrarySourceController.defaultsKey) }
    let server = StubMusicBackend(library: .sample(artistCount: 25), sourceID: "server", displayName: "Server")
    let folder = StubMusicBackend(library: .sample(artistCount: 3), sourceID: "folder", displayName: "Local Folder")
    let serverFlag = ConfiguredFlag()
    let folderFlag = ConfiguredFlag()
    let controller = LibrarySourceController(
        sources: [
            LibrarySource(backend: server, isConfigured: { serverFlag.value }),
            LibrarySource(backend: folder, isConfigured: { folderFlag.value }, probe: folderProbe),
        ],
        defaultSourceID: defaultID, defaults: defaults, searchDelay: .milliseconds(20))
    return SourceFixture(
        server: server, folder: folder, serverConfigured: serverFlag, folderConfigured: folderFlag,
        defaults: defaults, controller: controller, suiteName: suiteName)
}

/// A playing snapshot with `title`.
func snapshot(title: String, on output: OutputDevice.ID = OutputDevice.thisMacID) -> NowPlaying {
    NowPlaying(output: output, state: .playing, title: title)
}

// MARK: Fallback

/// A clock the test advances by hand. `sleep` parks until `advance(by:)` passes its deadline; cancellation ends it.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, resume, cancel }
                let outcome = state.withLock { s -> Outcome in
                    if Task.isCancelled { return .cancel }
                    if deadline <= s.now { return .resume }
                    s.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed, earliest first.
    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: duration)
            let ready = s.sleepers.filter { $0.value.deadline <= s.now }
            for key in ready.keys { s.sleepers.removeValue(forKey: key) }
            return ready.values.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// What a test's folder probe answers, and how often it was asked.
final class FolderCheck: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (error: MusicBackendError?.none, count: 0))
    var error: MusicBackendError? {
        get { lock.withLock { $0.error } }
        set { lock.withLock { $0.error = newValue } }
    }
    var count: Int { lock.withLock { $0.count } }
    func run() throws {
        let error = lock.withLock { s -> MusicBackendError? in
            s.count += 1
            return s.error
        }
        if let error { throw error }
    }
}

@MainActor
final class NoticeLog {
    var notices: [FallbackNotice] = []
}

struct FallbackFixture {
    var sources: SourceFixture
    var clock: ManualClock
    var fallback: LibraryFallbackController
    var notices: NoticeLog
    var folderCheck: FolderCheck

    var server: StubMusicBackend { sources.server }
    var folder: StubMusicBackend { sources.folder }
    var controller: LibrarySourceController { sources.controller }
    var defaults: UserDefaults { sources.defaults }

    @MainActor func cleanUp() {
        fallback.stop()
        sources.cleanUp()
    }
}

/// Two stubs behind a controller, a `ManualClock` and the fallback driver. Nothing is started: call `fallback.start()`.
@MainActor
func makeFallback(
    stored: String? = nil, serverConfigured: Bool = true, folderConfigured: Bool = true,
    schedule: RetrySchedule = .default
) -> FallbackFixture {
    let check = FolderCheck()
    let sources = makeSources(stored: stored, folderProbe: SourceProbes.checking { try check.run() })
    sources.serverConfigured.value = serverConfigured
    sources.folderConfigured.value = folderConfigured
    let clock = ManualClock()
    let fallback = LibraryFallbackController(sources: sources.controller, schedule: schedule, clock: clock)
    let log = NoticeLog()
    fallback.onNotice = { log.notices.append($0) }
    return FallbackFixture(sources: sources, clock: clock, fallback: fallback, notices: log, folderCheck: check)
}
