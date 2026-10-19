import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import os
import Testing
@testable import MusicAssistantKit

/// The test token. Never a real one; the secrecy tests look for exactly this string.
let testToken = MusicAssistantToken("ma-UNIT-TEST-TOKEN")
let testBaseURL = URL(string: "http://ma.example:8095")!
/// The scrubbed server id in `server-info.json`.
let fixtureServerID = "0123456789abcdef0123456789abcdef"
let testAddress = MusicAssistantServerAddress(baseURL: testBaseURL, serverID: fixtureServerID)

/// Polls until `condition` holds (up to `timeout` seconds). No fixed sleeps in the happy path.
func waitFor(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

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
    /// The pending sleepers' absolute deadlines (offsets from zero), sorted. Tells apart loops sharing the clock (#0083).
    var sleeperDeadlines: [Duration] { state.withLock { $0.sleepers.values.map(\.deadline.offset).sorted() } }

    /// true when some sleeper's deadline is exactly `duration` from now: a loop that just called `sleep(for: duration)`.
    func hasSleeper(dueIn duration: Duration) -> Bool {
        let now = self.now.offset
        return sleeperDeadlines.contains(now + duration)
    }

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

/// Counts calls from a `@Sendable` closure.
final class CallCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { lock.withLock { $0 } }
    func hit() { lock.withLock { $0 += 1 } }
}

struct ClientRig {
    var client: MusicAssistantClient
    var factory: StubTransportFactory
    var transport: StubWebSocketTransport
    var clock: ManualClock

    func connect(expectedServerID: String? = nil) async throws -> MAServerInfo {
        try await client.connect(token: testToken, expectedServerID: expectedServerID)
    }
}

/// A client over scripted transports (the first is `transport`; extra ones serve reconnects) and a `ManualClock`.
func makeClient(
    script: FixtureScript? = nil, extraTransports: [StubWebSocketTransport] = [], connectError: MusicAssistantError? = nil
) throws -> ClientRig {
    let script = try script ?? FixtureScript.recorded(token: testToken)
    let first = StubWebSocketTransport(script: script, connectError: connectError)
    let factory = StubTransportFactory(transports: [first] + extraTransports, script: script)
    let clock = ManualClock()
    let client = MusicAssistantClient(
        baseURL: testBaseURL, transports: factory, http: StubHTTPTransport(), clock: clock,
        reconnect: ReconnectPolicy(steps: ReconnectPolicy.default.steps, cap: .seconds(30), jitter: 0))
    return ClientRig(client: client, factory: factory, transport: first, clock: clock)
}

struct BackendRig {
    var backend: MusicAssistantBackend
    var factory: StubTransportFactory
    var http: StubHTTPTransport
    var tokenCalls: CallCounter
    var clock: ManualClock

    var transport: StubWebSocketTransport { factory.transports[0] }
}

func makeBackend(
    address: MusicAssistantServerAddress? = testAddress, token: MusicAssistantToken? = testToken,
    script: FixtureScript? = nil, connectError: MusicAssistantError? = nil
) throws -> BackendRig {
    let script = try script ?? FixtureScript.recorded(token: testToken)
    let factory = StubTransportFactory(
        transports: [StubWebSocketTransport(script: script, connectError: connectError)], script: script)
    let http = StubHTTPTransport()
    let calls = CallCounter()
    let clock = ManualClock()
    let backend = MusicAssistantBackend(
        address: { address }, token: { _ in calls.hit(); return token }, transports: factory, http: http, clock: clock)
    return BackendRig(backend: backend, factory: factory, http: http, tokenCalls: calls, clock: clock)
}

/// A connected backend.
func connectedBackend(script: FixtureScript? = nil) async throws -> BackendRig {
    let rig = try makeBackend(script: script)
    try await rig.backend.connect()
    return rig
}

func frameObject(_ text: String) throws -> MAJSON {
    try MAJSON.parse(text)
}

/// The `result` of the first recorded frame of `fixture`.
func recordedResult(_ fixture: MAFixture, frame: Int = 0) throws -> MAJSON {
    try #require(try fixture.frames()[frame]["result"])
}

/// A handshake message with some fields overridden.
func handshake(overriding changes: [String: MAJSON]) throws -> [String] {
    guard case .object(var object) = try MAFixture.serverInfo.frames()[0] else { return [] }
    for (key, value) in changes { object[key] = value }
    return [MAJSON.object(object).encodedString()]
}

func scriptWith(handshake: [String]) throws -> FixtureScript {
    var script = try FixtureScript.recorded(token: testToken)
    script.handshake = handshake
    return script
}

/// Gathers an async sequence's elements in the background so a test polls with `waitFor` instead of risking a hang.
final class Collector<Element: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (items: [Element](), finished: false))
    private var task: Task<Void, Never>?

    init<S: AsyncSequence & Sendable>(_ sequence: S) where S.Element == Element {
        task = Task { [lock] in
            do {
                for try await element in sequence { lock.withLock { $0.items.append(element) } }
            } catch {}
            lock.withLock { $0.finished = true }
        }
    }

    var items: [Element] { lock.withLock { $0.items } }
    var finished: Bool { lock.withLock { $0.finished } }
    func stop() { task?.cancel() }
}
