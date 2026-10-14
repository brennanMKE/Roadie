import Foundation
import MusicAssistantKit
import os

/// One request the client sent, parsed.
public struct SentRequest: Sendable, Hashable {
    public var command: String
    public var args: MAJSON
    public var messageID: String
}

/// A scripted WebSocket. `connect()` queues the script's handshake; every `send` is recorded and answered from the
/// script; `push` and `closeFromServer` inject server-initiated messages.
public final class StubWebSocketTransport: MAWebSocketTransport, @unchecked Sendable {
    public enum ReplyOrder: Sendable {
        case inOrder
        /// Replies to every two requests are delivered second-first, to prove correlation by `message_id`.
        case reversedPairs
    }

    private struct State {
        var script: FixtureScript
        var connectError: MusicAssistantError?
        var sent: [String] = []
        var sentRequests: [SentRequest] = []
        var closeCodes: [Int] = []
        var pingCount = 0
        var pingError: MusicAssistantError?
        var pingHangs = false
        var pingWaiter: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?
        var inbound: [MAWebSocketFrame] = []
        var waiter: (id: UUID, continuation: CheckedContinuation<MAWebSocketFrame, any Error>)?
        var held: Set<String> = []
        var heldReplies: [String: [[String]]] = [:]
        var unanswered: Set<String> = []
        var replyOrder: ReplyOrder = .inOrder
        var reorder: [[String]] = []
        var closed = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(script: FixtureScript, connectError: MusicAssistantError? = nil) {
        var initial = State(script: script)
        initial.connectError = connectError
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    // MARK: Inspection and control

    public var script: FixtureScript {
        get { state.withLock { $0.script } }
        set { state.withLock { $0.script = newValue } }
    }
    public var connectError: MusicAssistantError? {
        get { state.withLock { $0.connectError } }
        set { state.withLock { $0.connectError = newValue } }
    }
    public var pingError: MusicAssistantError? {
        get { state.withLock { $0.pingError } }
        set { state.withLock { $0.pingError = newValue } }
    }
    /// Pings never get a pong; `ping()` waits until cancelled.
    public var pingHangs: Bool {
        get { state.withLock { $0.pingHangs } }
        set { state.withLock { $0.pingHangs = newValue } }
    }
    /// Commands that never get an answer.
    public var unanswered: Set<String> {
        get { state.withLock { $0.unanswered } }
        set { state.withLock { $0.unanswered = newValue } }
    }
    public var replyOrder: ReplyOrder {
        get { state.withLock { $0.replyOrder } }
        set { state.withLock { $0.replyOrder = newValue } }
    }
    /// Every outbound text, verbatim.
    public var sent: [String] { state.withLock { $0.sent } }
    public var sentRequests: [SentRequest] { state.withLock { $0.sentRequests } }
    public var closeCodes: [Int] { state.withLock { $0.closeCodes } }
    public var pingCount: Int { state.withLock { $0.pingCount } }

    /// Server-initiated text (an event, a stray message).
    public func push(_ text: String) {
        enqueue([.text(text)])
    }

    /// Ends the client's `receive()` with a close.
    public func closeFromServer(code: Int? = 1006) {
        enqueue([.closed(code: code)])
    }

    /// Answers to `command` are kept back until `release(command:)`.
    public func holdReplies(for command: String) {
        state.withLock { _ = $0.held.insert(command) }
    }

    public func release(command: String) {
        let texts = state.withLock { s -> [String] in
            s.held.remove(command)
            return (s.heldReplies.removeValue(forKey: command) ?? []).flatMap { $0 }
        }
        enqueue(texts.map { .text($0) })
    }

    private func enqueue(_ frames: [MAWebSocketFrame]) {
        guard !frames.isEmpty else { return }
        let wake = state.withLock { s -> (CheckedContinuation<MAWebSocketFrame, any Error>, MAWebSocketFrame)? in
            s.inbound.append(contentsOf: frames)
            if let waiter = s.waiter {
                s.waiter = nil
                return (waiter.continuation, s.inbound.removeFirst())
            }
            return nil
        }
        if let wake { wake.0.resume(returning: wake.1) }
    }

    // MARK: MAWebSocketTransport

    public func connect() async throws {
        let (error, handshake) = state.withLock { ($0.connectError, $0.script.handshake) }
        if let error { throw error }
        enqueue(handshake.map { .text($0) })
    }

    public func send(_ text: String) async throws {
        let (script, closed) = state.withLock { ($0.script, $0.closed) }
        if closed { throw MusicAssistantError.disconnected }
        let parsed = try? MAJSON.parse(text)
        let command = parsed?["command"]?.stringValue ?? ""
        let args = parsed?["args"] ?? .object([:])
        let messageID = parsed?["message_id"]?.stringValue ?? ""
        let replies = script.replies(command: command, args: args, messageID: messageID)
        let deliver = state.withLock { s -> [String] in
            s.sent.append(text)
            s.sentRequests.append(SentRequest(command: command, args: args, messageID: messageID))
            if s.unanswered.contains(command) { return [] }
            if s.held.contains(command) {
                s.heldReplies[command, default: []].append(replies)
                return []
            }
            switch s.replyOrder {
            case .inOrder:
                return replies
            case .reversedPairs:
                s.reorder.append(replies)
                guard s.reorder.count >= 2 else { return [] }
                let out = s.reorder.reversed().flatMap { $0 }
                s.reorder = []
                return out
            }
        }
        enqueue(deliver.map { .text($0) })
    }

    public func receive() async throws -> MAWebSocketFrame {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MAWebSocketFrame, any Error>) in
                enum Outcome {
                    case frame(MAWebSocketFrame)
                    case cancelled
                    case closed
                    case wait
                }
                let outcome = state.withLock { s -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if !s.inbound.isEmpty { return .frame(s.inbound.removeFirst()) }
                    if s.closed { return .closed }
                    s.waiter = (id, continuation)
                    return .wait
                }
                switch outcome {
                case .frame(let frame): continuation.resume(returning: frame)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .closed: continuation.resume(throwing: MusicAssistantError.disconnected)
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<MAWebSocketFrame, any Error>? in
                guard let waiter = s.waiter, waiter.id == id else { return nil }
                s.waiter = nil
                return waiter.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    public func ping() async throws {
        let (error, hangs) = state.withLock { s -> (MusicAssistantError?, Bool) in
            s.pingCount += 1
            return (s.pingError, s.pingHangs)
        }
        if let error { throw error }
        guard hangs else { return }
        // No pong: wait until cancelled, like the real transport.
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { s -> Bool in
                    if Task.isCancelled { return true }
                    s.pingWaiter = (id, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                guard let waiter = s.pingWaiter, waiter.id == id else { return nil }
                s.pingWaiter = nil
                return waiter.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    public func close(code: Int) async {
        let waiter = state.withLock { s -> CheckedContinuation<MAWebSocketFrame, any Error>? in
            s.closeCodes.append(code)
            s.closed = true
            let waiter = s.waiter?.continuation
            s.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: MusicAssistantError.disconnected)
    }
}

/// Hands out scripted transports in order, then fresh ones over `script`.
public final class StubTransportFactory: MAWebSocketTransportFactory, @unchecked Sendable {
    private struct State {
        var queue: [StubWebSocketTransport]
        var made: [StubWebSocketTransport] = []
        var urls: [URL] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let script: FixtureScript

    public init(transports: [StubWebSocketTransport] = [], script: FixtureScript = FixtureScript()) {
        state = OSAllocatedUnfairLock(initialState: State(queue: transports))
        self.script = script
    }

    public func makeTransport(url: URL) -> any MAWebSocketTransport {
        state.withLock { s -> StubWebSocketTransport in
            let transport = s.queue.isEmpty ? StubWebSocketTransport(script: script) : s.queue.removeFirst()
            s.made.append(transport)
            s.urls.append(url)
            return transport
        }
    }

    /// How many transports the client has asked for.
    public var made: Int { state.withLock { $0.made.count } }
    public var transports: [StubWebSocketTransport] { state.withLock { $0.made } }
    public var urls: [URL] { state.withLock { $0.urls } }
}
