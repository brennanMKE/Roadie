import Foundation
import os

/// A WebSocket client for Music Assistant's API: server-info handshake, `auth`, message-id correlation,
/// partial-result assembly, pushed events, a heartbeat and reconnect with backoff and re-auth.
///
/// The token is held here only to re-authenticate after a reconnect, is sent only in the `auth` message and
/// is never logged, put in a URL or carried by an error. Logging records state changes, command names,
/// message ids, error codes and counts, never a message body, an argument, a host or a URL.
public actor MusicAssistantClient {
    public enum ConnectionState: Hashable, Sendable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case reconnecting(attempt: Int)
        case failed(MusicAssistantError)
    }

    /// The schema the models were recorded against.
    public static let supportedSchemaVersion = 65
    /// The first schema with `auth`.
    public static let minimumSchemaVersion = 28

    private struct Pending {
        var command: String
        var continuation: CheckedContinuation<MAJSON, any Error>
        var accumulator: MAJSON?
        var timeoutTask: Task<Void, Never>?
    }

    private let baseURL: URL
    private let transports: any MAWebSocketTransportFactory
    private let http: any MAHTTPTransport
    private let clock: any Clock<Duration>
    private let pingInterval: Duration
    private let pongTimeout: Duration
    private let callTimeout: Duration
    private let reconnectPolicy: ReconnectPolicy
    private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "MusicAssistant")

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var serverInfo: MAServerInfo?
    /// Transports created so far (tests).
    public private(set) var connectionCount = 0
    /// Calls waiting for an answer (tests).
    public var pendingCallCount: Int { pending.count }

    private var generation = 0
    private var transport: (any MAWebSocketTransport)?
    private var outbound: AsyncStream<String>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var nextMessageID = 1
    private var pending: [String: Pending] = [:]
    private var token: MusicAssistantToken?
    private var expectedServerID: String?
    private var userDisconnected = false
    private var eventContinuations: [UUID: AsyncStream<MAServerEvent>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    public init(
        baseURL: URL,
        transports: any MAWebSocketTransportFactory = URLSessionWebSocketTransportFactory(),
        http: any MAHTTPTransport = URLSessionHTTPTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        pingInterval: Duration = .seconds(25),
        pongTimeout: Duration = .seconds(10),
        callTimeout: Duration = .seconds(15),
        reconnect: ReconnectPolicy = .default
    ) {
        self.baseURL = baseURL
        self.transports = transports
        self.http = http
        self.clock = clock
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.callTimeout = callTimeout
        self.reconnectPolicy = reconnect
    }

    /// A client dropped without `disconnect()` stops its loops (they hold the transport, not the client).
    deinit {
        senderTask?.cancel()
        readerTask?.cancel()
        pingTask?.cancel()
        reconnectTask?.cancel()
        outbound?.finish()
    }

    // MARK: Probe

    /// `GET /info`: no token, no socket. For reachability checks and the identity comparison.
    public static func serverInfo(
        at baseURL: URL, http: any MAHTTPTransport = URLSessionHTTPTransport(), timeout: Duration = .seconds(5)
    ) async throws -> MAServerInfo {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MusicAssistantError.invalidURL
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/info"
        components.query = nil
        guard let url = components.url else { throw MusicAssistantError.invalidURL }
        let response: MAHTTPResponse
        do {
            response = try await http.get(url, headers: [:], timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw MusicAssistantError.transport(error.code)
        } catch {
            throw MusicAssistantError.transport(.unknown)
        }
        guard response.status == 200 else { throw MusicAssistantError.handshakeFailed }
        do {
            return try JSONDecoder().decode(MAServerInfo.self, from: response.body)
        } catch {
            throw MusicAssistantError.handshakeFailed
        }
    }

    // MARK: Streams

    /// The current state first, then every change.
    public func states() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        stateContinuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return stream
    }

    /// Pushed messages only. A slow subscriber drops the oldest rather than growing without bound.
    public func events() -> AsyncStream<MAServerEvent> {
        let (stream, continuation) = AsyncStream<MAServerEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return stream
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeEventContinuation(_ id: UUID) { eventContinuations[id] = nil }

    private func setState(_ new: ConnectionState) {
        guard new != state else { return }
        state = new
        log.info("state \(String(describing: new), privacy: .public)")
        for continuation in stateContinuations.values { continuation.yield(new) }
    }

    private func finishEventStreams() {
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations = [:]
    }

    // MARK: Connect and disconnect

    /// Handshake and `auth`. Compares `expectedServerID` with the first message BEFORE the token leaves the process.
    @discardableResult
    public func connect(token: MusicAssistantToken, expectedServerID: String? = nil) async throws -> MAServerInfo {
        if state == .connected, let serverInfo { return serverInfo }
        reconnectTask?.cancel()
        reconnectTask = nil
        if let old = transport {
            generation += 1
            teardownTasks()
            failAllPending(.disconnected)
            transport = nil
            await old.close(code: 1000)
        }
        userDisconnected = false
        self.token = token
        self.expectedServerID = expectedServerID
        setState(.connecting)
        do {
            return try await establish()
        } catch {
            self.token = nil
            if let failure = error as? MusicAssistantError {
                setState(.failed(failure))
                throw failure
            }
            throw error
        }
    }

    /// Sends a normal close, drops the token and stops reconnecting.
    public func disconnect() async {
        userDisconnected = true
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownTasks()
        failAllPending(.disconnected)
        let old = transport
        transport = nil
        token = nil
        expectedServerID = nil
        serverInfo = nil
        setState(.disconnected)
        await old?.close(code: 1000)
    }

    /// One connection attempt: upgrade, server info, checks, `auth`, then the loops. Throws `MusicAssistantError`
    /// (or `CancellationError`); on any failure the socket is closed and nothing is left running.
    private func establish() async throws -> MAServerInfo {
        guard let token else { throw MusicAssistantError.notConnected }
        generation += 1
        let gen = generation
        nextMessageID = 1
        let transport = transports.makeTransport(url: baseURL)
        connectionCount += 1
        self.transport = transport
        do {
            try await transport.connect()
            let first = try await Self.nextText(
                transport, clock: clock, timeout: callTimeout, timeoutError: .handshakeFailed, closedError: .handshakeFailed)
            guard case .serverInfo(let info) = MAEnvelope.parse(first) else { throw MusicAssistantError.handshakeFailed }
            try ensureCurrent(gen)
            guard info.minSupportedSchemaVersion <= Self.supportedSchemaVersion, info.schemaVersion >= Self.minimumSchemaVersion else {
                throw MusicAssistantError.schemaUnsupported(server: info.schemaVersion, minSupported: info.minSupportedSchemaVersion)
            }
            if let expected = expectedServerID, expected != info.serverID { throw MusicAssistantError.serverMismatch }
            setState(.authenticating)
            try await transport.send(MARequest.auth(token: token).encodedFrame(messageID: "1"))
            nextMessageID = 2
            try await awaitAuthReply(transport)
            try ensureCurrent(gen)
            activate(info: info, transport: transport, generation: gen)
            return info
        } catch {
            if generation == gen { self.transport = nil }
            await transport.close(code: 1000)
            if error is CancellationError || error is MusicAssistantError { throw error }
            throw MusicAssistantError.disconnected
        }
    }

    private func ensureCurrent(_ gen: Int) throws {
        if gen != generation { throw CancellationError() }
    }

    private func awaitAuthReply(_ transport: any MAWebSocketTransport) async throws {
        while true {
            let text = try await Self.nextText(
                transport, clock: clock, timeout: callTimeout, timeoutError: .timeout(command: "auth"), closedError: .disconnected)
            switch MAEnvelope.parse(text) {
            case .result(let id, let result, _) where id == "1":
                guard let auth = try? result.decode(as: MAAuthResult.self), auth.authenticated else {
                    throw MusicAssistantError.tokenRejected
                }
                return
            case .error(let id, let code, let details) where id == "1":
                throw Self.map(code: code, details: details)
            default:
                continue
            }
        }
    }

    private func activate(info: MAServerInfo, transport: any MAWebSocketTransport, generation gen: Int) {
        serverInfo = info
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        outbound = continuation
        senderTask = Task { [weak self] in
            for await text in stream {
                do {
                    try await transport.send(text)
                } catch {
                    await self?.connectionLost(generation: gen)
                    return
                }
            }
        }
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                let received: MAWebSocketFrame
                do {
                    received = try await transport.receive()
                } catch {
                    await self?.connectionLost(generation: gen)
                    return
                }
                switch received {
                case .closed:
                    await self?.connectionLost(generation: gen)
                    return
                case .text(let body):
                    guard let self else { return }
                    await self.handle(body, generation: gen)
                }
            }
        }
        let clock = self.clock
        let pingInterval = self.pingInterval
        let pongTimeout = self.pongTimeout
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: pingInterval)
                } catch {
                    return
                }
                let healthy = await Self.ping(transport, clock: clock, timeout: pongTimeout)
                if Task.isCancelled { return }
                if !healthy {
                    await self?.connectionLost(generation: gen)
                    return
                }
            }
        }
        setState(.connected)
    }

    private func teardownTasks() {
        senderTask?.cancel()
        senderTask = nil
        readerTask?.cancel()
        readerTask = nil
        pingTask?.cancel()
        pingTask = nil
        outbound?.finish()
        outbound = nil
    }

    // MARK: Connection loss and reconnect

    private func connectionLost(generation lost: Int) {
        guard lost == generation, !userDisconnected else { return }
        generation += 1
        teardownTasks()
        failAllPending(.disconnected)
        let old = transport
        transport = nil
        if let old { Task { await old.close(code: 1000) } }
        startReconnect()
    }

    private func startReconnect() {
        reconnectTask?.cancel()
        setState(.reconnecting(attempt: 1))
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        var attempt = 1
        while !Task.isCancelled, !userDisconnected {
            setState(.reconnecting(attempt: attempt))
            let delay = reconnectPolicy.delay(attempt: attempt)
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            if Task.isCancelled || userDisconnected { return }
            do {
                _ = try await establish()
                return
            } catch is CancellationError {
                return
            } catch let failure as MusicAssistantError {
                switch failure {
                case .tokenRejected, .unauthenticated, .schemaUnsupported, .serverMismatch:
                    stopReconnecting(failure)
                    return
                default:
                    attempt += 1
                }
            } catch {
                attempt += 1
            }
        }
    }

    /// A dead token or a wrong server will not heal by retrying.
    private func stopReconnecting(_ failure: MusicAssistantError) {
        token = nil
        setState(.failed(failure))
        finishEventStreams()
    }

    // MARK: Calls

    public func call(_ request: MARequest, timeout: Duration? = nil) async throws -> MAJSON {
        guard state == .connected, outbound != nil else { throw MusicAssistantError.notConnected }
        let id = String(nextMessageID)
        nextMessageID += 1
        let gen = generation
        let limit = timeout ?? request.timeout ?? callTimeout
        let body = request.encodedFrame(messageID: id)
        let command = request.command
        log.debug("call \(command, privacy: .public) id \(id, privacy: .public)")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MAJSON, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let clock = self.clock
                let timeoutTask = Task { [weak self] in
                    do {
                        try await clock.sleep(for: limit)
                    } catch {
                        return
                    }
                    await self?.timeOut(id: id, generation: gen)
                }
                pending[id] = Pending(command: command, continuation: continuation, accumulator: nil, timeoutTask: timeoutTask)
                outbound?.yield(body)
            }
        } onCancel: {
            Task { await self.cancelCall(id: id, generation: gen) }
        }
    }

    public func call<T: Decodable & Sendable>(_ request: MARequest, as type: T.Type, timeout: Duration? = nil) async throws -> T {
        let json = try await call(request, timeout: timeout)
        do {
            return try json.decode(as: T.self)
        } catch {
            throw MusicAssistantError.decoding(command: request.command, detail: Self.describe(error))
        }
    }

    private func timeOut(id: String, generation gen: Int) {
        guard gen == generation, let entry = pending.removeValue(forKey: id) else { return }
        log.info("call \(entry.command, privacy: .public) id \(id, privacy: .public) timed out")
        entry.continuation.resume(throwing: MusicAssistantError.timeout(command: entry.command))
    }

    private func cancelCall(id: String, generation gen: Int) {
        guard gen == generation, let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(throwing: CancellationError())
    }

    private func failAllPending(_ error: MusicAssistantError) {
        let all = pending
        pending = [:]
        for entry in all.values {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    private func handle(_ body: String, generation gen: Int) {
        guard gen == generation else { return }
        switch MAEnvelope.parse(body) {
        case .result(let id, let result, let partial):
            guard var entry = pending[id] else {
                log.debug("dropped a reply for unknown id \(id, privacy: .public)")
                return
            }
            switch result {
            case .array(let chunk):
                if case .array(let existing)? = entry.accumulator {
                    entry.accumulator = .array(existing + chunk)
                } else {
                    entry.accumulator = .array(chunk)
                }
            case .null:
                break
            default:
                entry.accumulator = result
            }
            if partial {
                pending[id] = entry
            } else {
                pending[id] = nil
                entry.timeoutTask?.cancel()
                entry.continuation.resume(returning: entry.accumulator ?? .null)
            }
        case .error(let id, let code, let details):
            guard let entry = pending.removeValue(forKey: id) else {
                log.debug("dropped an error for unknown id \(id, privacy: .public)")
                return
            }
            entry.timeoutTask?.cancel()
            log.info("call \(entry.command, privacy: .public) id \(id, privacy: .public) failed with code \(code)")
            entry.continuation.resume(throwing: Self.map(code: code, details: details))
        case .event(let event):
            log.debug("event \(event.event, privacy: .public)")
            for continuation in eventContinuations.values { continuation.yield(event) }
        case .serverInfo, .unknown:
            log.debug("dropped an unexpected message")
        }
    }

    // MARK: Helpers

    static func map(code: Int, details: String) -> MusicAssistantError {
        switch code {
        case 20: .unauthenticated
        case 23: .tokenRejected
        default: .server(code: code, details: details)
        }
    }

    /// The failure kind and coding path only: never a value from the answer.
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "unreadable" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case .typeMismatch(_, let context): return "type mismatch at \(path(context))"
        case .valueNotFound(_, let context): return "missing value at \(path(context))"
        case .keyNotFound(let key, let context): return "missing key \(key.stringValue) at \(path(context))"
        case .dataCorrupted(let context): return "corrupt data at \(path(context))"
        @unknown default: return "unreadable"
        }
    }

    /// The next text message, or `timeoutError` after `timeout` (through `clock`), or `closedError` on a close.
    private static func nextText(
        _ transport: any MAWebSocketTransport, clock: any Clock<Duration>, timeout: Duration,
        timeoutError: MusicAssistantError, closedError: MusicAssistantError
    ) async throws -> String {
        let received: MAWebSocketFrame? = try await withThrowingTaskGroup(of: MAWebSocketFrame?.self) { group in
            group.addTask { try await transport.receive() }
            group.addTask {
                try await clock.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            if let first = try await group.next() { return first }
            return nil
        }
        guard let received else { throw timeoutError }
        switch received {
        case .text(let body): return body
        case .closed: throw closedError
        }
    }

    /// true when the pong arrives within `timeout`.
    private static func ping(_ transport: any MAWebSocketTransport, clock: any Clock<Duration>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await transport.ping()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                    return false
                } catch {
                    return true
                }
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}
