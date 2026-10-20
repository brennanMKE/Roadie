import Foundation
import os
import Testing
@testable import SendspinKit

let testToken = "sendspin-UNIT-TEST-TOKEN"
let testClientID = "skinamp-test-client"

func testConfiguration() -> SendspinConnectionConfiguration {
    SendspinConnectionConfiguration(
        baseURL: URL(string: "http://ma.example:8095")!, token: testToken, clientID: testClientID, name: "SkinAmp test",
        deviceInfo: SendspinDeviceInfo(softwareVersion: "test"), format: SendspinAudioFormat(sampleRate: 48_000))
}

/// Polls until `condition` holds (up to `timeout` seconds).
func waitFor(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// The fixture's frames, in order.
func fixtureFrames() throws -> [(dir: String, frame: [String: Any], recorded: Bool)] {
    let url = try #require(Bundle.module.url(forResource: "sendspin-legacy-session", withExtension: "json", subdirectory: "Fixtures"))
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let frames = root?["frames"] as? [[String: Any]] ?? []
    return frames.map { ($0["dir"] as? String ?? "", $0["frame"] as? [String: Any] ?? [:], $0["recorded"] as? Bool ?? false) }
}

func fixtureText(type: String, index: Int = 0) throws -> String {
    let matches = try fixtureFrames().filter { $0.frame["type"] as? String == type }
    let data = try JSONSerialization.data(withJSONObject: matches[index].frame, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

func jsonObject(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

func messageType(_ text: String) -> String { jsonObject(text)["type"] as? String ?? "" }

/// Advances by `step` µs on every read, so each exchange has increasing, distinct timestamps.
final class FakeSendspinClock: SendspinClock, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<Int64>
    let step: Int64

    init(start: Int64 = 1_000_000, step: Int64 = 500) {
        state = OSAllocatedUnfairLock(initialState: start)
        self.step = step
    }

    func nowMicros() -> Int64 {
        state.withLock { now in
            now += step
            return now
        }
    }
}

/// A server clock: offset plus a fixed one-way delay and processing time.
struct FakeServerClock: Sendable {
    var offset: Int64 = 5_000_000
    var oneWay: Int64 = 200
    var processing: Int64 = 50

    func reply(to t1: Int64) -> SendspinServerTime {
        let received = t1 + oneWay + offset
        return SendspinServerTime(clientTransmitted: t1, serverReceived: received, serverTransmitted: received + processing)
    }
}

/// `Clock<Duration>` that records sleeps. Sleeps shorter than 10 s return at once; longer ones (the burst
/// interval) wait until cancelled, so the periodic burst does not spin.
final class TestSleeper: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    private let released: OSAllocatedUnfairLock<Int>

    /// The first `releasedBursts` sleeps of 10 s or longer return at once; later ones block.
    init(releasedBursts: Int = 0) {
        released = OSAllocatedUnfairLock(initialState: releasedBursts)
    }
    var sleeps: [Duration] { recorded.withLock { $0 } }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let duration = deadline.offset
        recorded.withLock { $0.append(duration) }
        if duration >= .seconds(10) {
            let release = released.withLock { remaining -> Bool in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if release { return try Task.checkCancellation() }
            try await Task.sleep(for: .seconds(3_600))
        }
        try Task.checkCancellation()
    }
}

final class StubSendspinTransport: SendspinTransport, @unchecked Sendable {
    enum AuthReply { case ok, unauthorized }

    private struct State {
        var sent: [String] = []
        var queue: [SendspinFrame] = []
        var waiter: CheckedContinuation<SendspinFrame, any Error>?
        var holdTime = false
        var heldTimes: [Int64] = []
        var closed = false
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let auth: AuthReply
    let server: FakeServerClock

    init(auth: AuthReply = .ok, server: FakeServerClock = FakeServerClock()) {
        self.auth = auth
        self.server = server
    }

    var sent: [String] { state.withLock { $0.sent } }
    var sentTypes: [String] { sent.map(messageType) }

    /// While held, `client/time` requests are recorded but not answered.
    func holdTime(_ hold: Bool) {
        let held: [Int64] = state.withLock { s in
            s.holdTime = hold
            if hold { return [] }
            defer { s.heldTimes = [] }
            return s.heldTimes
        }
        for t1 in held { push(.text(SendspinOutgoing.encode(type: "server/time", payload: server.reply(to: t1)))) }
    }

    func push(_ frame: SendspinFrame) {
        let waiter: CheckedContinuation<SendspinFrame, any Error>? = state.withLock { s in
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            s.queue.append(frame)
            return nil
        }
        waiter?.resume(returning: frame)
    }

    func connect() async throws {}

    func send(text: String) async throws {
        state.withLock { $0.sent.append(text) }
        let object = jsonObject(text)
        switch object["type"] as? String {
        case "auth":
            switch auth {
            case .ok: push(.text(#"{"type":"auth_ok"}"#))
            case .unauthorized: push(.closed(code: 4001, reason: "Invalid or expired token"))
            }
        case "client/hello":
            push(.text(try fixtureText(type: "server/hello")))
        case "client/time":
            guard let payload = object["payload"] as? [String: Any], let t1 = (payload["client_transmitted"] as? NSNumber)?.int64Value
            else { return }
            let held = state.withLock { s -> Bool in
                if s.holdTime { s.heldTimes.append(t1) }
                return s.holdTime
            }
            if !held { push(.text(SendspinOutgoing.encode(type: "server/time", payload: server.reply(to: t1)))) }
        default:
            break
        }
    }

    func receive() async throws -> SendspinFrame {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendspinFrame, any Error>) in
                let outcome: Result<SendspinFrame, any Error>? = state.withLock { s in
                    if !s.queue.isEmpty { return .success(s.queue.removeFirst()) }
                    if s.cancelled { return .failure(CancellationError()) }
                    s.waiter = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter: CheckedContinuation<SendspinFrame, any Error>? = state.withLock { s in
                s.cancelled = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func close(code: Int) async {
        state.withLock { $0.closed = true }
    }
}

final class StubSendspinTransportFactory: SendspinTransportFactory, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(queued: [StubSendspinTransport], made: [StubSendspinTransport])>

    init(_ transports: [StubSendspinTransport] = []) {
        state = OSAllocatedUnfairLock(initialState: (transports, []))
    }

    var made: [StubSendspinTransport] { state.withLock { $0.made } }

    func makeTransport(url: URL) -> any SendspinTransport {
        state.withLock { s in
            let next = s.queued.isEmpty ? StubSendspinTransport() : s.queued.removeFirst()
            s.made.append(next)
            return next
        }
    }
}

/// Collects session events in the background.
final class EventRecorder: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[SendspinEvent]>(initialState: [])
    private var task: Task<Void, Never>?

    init(_ session: SendspinSession) async {
        let stream = await session.events()
        task = Task { [state] in
            for await event in stream { state.withLock { $0.append(event) } }
        }
    }

    var events: [SendspinEvent] { state.withLock { $0 } }

    func contains(_ predicate: (SendspinEvent) -> Bool) -> Bool { events.contains(where: predicate) }

    deinit { task?.cancel() }
}

func makeSession(
    factory: StubSendspinTransportFactory, sleeper: TestSleeper = TestSleeper(),
    clock: FakeSendspinClock = FakeSendspinClock()
) -> SendspinSession {
    SendspinSession(
        configuration: testConfiguration(), transports: factory, clock: clock, sleeper: sleeper,
        reconnect: SendspinReconnectPolicy(steps: [.seconds(1), .seconds(2)], cap: .seconds(30), jitter: 0))
}
