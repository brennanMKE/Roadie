import Foundation
import os

public enum SendspinEvent: Sendable, Equatable {
    case connected(SendspinServerHello)
    /// The clock has converged and `available: true` was sent.
    case synchronized
    case streamStarted(SendspinStreamFormat)
    /// `localMicros` is the chunk's server time mapped onto `SendspinClock` when it arrived.
    case audio(SendspinAudioChunk, localMicros: Int64)
    case streamCleared
    case streamEnded
    case setVolume(Int)
    case setMute(Bool)
    case groupUpdated(SendspinGroupUpdate)
    /// nil after a deliberate `stop`.
    case disconnected(SendspinError?)
}

/// How long to wait before reconnect attempt n (1-based). Same shape as MusicAssistantKit's `ReconnectPolicy`.
public struct SendspinReconnectPolicy: Hashable, Sendable {
    public var steps: [Duration]
    public var cap: Duration
    public var jitter: Double

    public init(steps: [Duration], cap: Duration, jitter: Double) {
        self.steps = steps
        self.cap = cap
        self.jitter = jitter
    }

    public static let standard = SendspinReconnectPolicy(
        steps: [.seconds(1), .seconds(2), .seconds(5), .seconds(10)], cap: .seconds(30), jitter: 0.2)

    public func delay(attempt: Int) -> Duration {
        let base = attempt >= 1 && attempt <= steps.count ? steps[attempt - 1] : cap
        let seconds = min(Self.seconds(base), Self.seconds(cap))
        guard jitter > 0 else { return .seconds(seconds) }
        return .seconds(seconds * (1 + Double.random(in: -jitter...jitter)))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The seam #0108 fakes.
public protocol SendspinSessionDriving: Sendable {
    func events() async -> AsyncStream<SendspinEvent>
    func start() async
    func stop(reason: SendspinGoodbyeReason) async
    func report(volume: Int, muted: Bool) async
}

/// A Sendspin `player@v1` client on the legacy wire through Music Assistant's authenticated `/sendspin` proxy.
public actor SendspinSession: SendspinSessionDriving {
    static let handshakeTimeout: Duration = .seconds(10)
    static let timeReplyTimeout: Duration = .seconds(2)
    static let unavailableStateAfter: Duration = .seconds(4)
    static let burstInterval: Duration = .seconds(10)
    static let unauthorizedCloseCode = 4001

    private let configuration: SendspinConnectionConfiguration
    private let transports: any SendspinTransportFactory
    private let clock: any SendspinClock
    private let sleeper: any Clock<Duration>
    private let reconnect: SendspinReconnectPolicy
    private let logger = Logger(subsystem: "co.sstools.roadie", category: "Sendspin")

    private let eventStream: AsyncStream<SendspinEvent>
    private let eventContinuation: AsyncStream<SendspinEvent>.Continuation

    private var runTask: Task<Void, Never>?
    private var transport: (any SendspinTransport)?
    private var stopped = false
    private var clockState = SendspinClockState()
    private var available = false
    private var volume = 100
    private var muted = false
    /// Audio chunks that arrived before the clock converged (should not happen: the server waits for `available`).
    public private(set) var droppedChunks = 0

    public init(
        configuration: SendspinConnectionConfiguration,
        transports: any SendspinTransportFactory = URLSessionSendspinTransportFactory(),
        clock: any SendspinClock = SystemSendspinClock(),
        sleeper: any Clock<Duration> = ContinuousClock(),
        reconnect: SendspinReconnectPolicy = .standard
    ) {
        self.configuration = configuration
        self.transports = transports
        self.clock = clock
        self.sleeper = sleeper
        self.reconnect = reconnect
        (eventStream, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func events() -> AsyncStream<SendspinEvent> { eventStream }

    public func start() {
        if running { return }
        stopped = false
        running = true
        runTask = Task { await self.run() }
    }

    private var running = false

    public func stop(reason: SendspinGoodbyeReason = .shutdown) async {
        stopped = true
        if let transport {
            try? await transport.send(text: SendspinOutgoing.encode(SendspinClientGoodbye(reason: reason)))
            await transport.close(code: 1000)
        }
        runTask?.cancel()
        await runTask?.value
        runTask = nil
    }

    public func report(volume: Int, muted: Bool) async {
        self.volume = min(max(volume, 0), 100)
        self.muted = muted
        try? await sendState()
    }

    public func setAvailable(_ available: Bool) async {
        self.available = available
        try? await sendState()
    }

    /// nil until the clock has converged.
    public func localMicros(forServer server: Int64) -> Int64? {
        clockState.isConverged ? clockState.filter.computeClientTime(server) : nil
    }

    // MARK: - Loop

    private func run() async {
        defer { running = false }
        let hasPrefix = !(configuration.baseURL.path.isEmpty || configuration.baseURL.path == "/")
        logger.info("Sendspin connecting (scheme \(self.configuration.baseURL.scheme ?? "?", privacy: .public), path prefix \(hasPrefix, privacy: .public))")
        var attempt = 0
        while !stopped && !Task.isCancelled {
            let transport = transports.makeTransport(url: configuration.sendspinURL())
            self.transport = transport
            let (error, reachedRunning) = await runConnection(transport)
            self.transport = nil
            clockState.reset()
            available = false
            if stopped || Task.isCancelled { break }
            logger.info("Sendspin disconnected: \(String(describing: error), privacy: .public)")
            eventContinuation.yield(.disconnected(error))
            if case .unauthorized = error { return }
            attempt = reachedRunning ? 1 : attempt + 1
            do {
                try await Self.sleep(sleeper, for: reconnect.delay(attempt: attempt))
            } catch {
                break
            }
        }
        eventContinuation.yield(.disconnected(nil))
    }

    private static func sleep<C: Clock>(_ clock: C, for duration: Duration) async throws where C.Duration == Duration {
        try await clock.sleep(for: duration)
    }

    private enum Phase: Equatable { case auth, hello, syncing, running }

    private enum Input: Sendable {
        case frame(SendspinFrame)
        case failed(String)
        case deadline(Phase)
        case timeTimeout(Int64)
        case stateDeadline
        case burstTick
    }

    // Per-connection state, reset by `runConnection`.
    private var phase = Phase.auth
    private var burst = SendspinClockBurst()
    private var attempts = 0
    private var pendingT1: Int64?
    private var input: AsyncStream<Input>.Continuation?
    private enum TimerSlot: Hashable { case handshake, stateDeadline, timeReply, burst }
    private var receiveTask: Task<Void, Never>?
    /// One task per purpose: storing a new timer cancels the one it replaces, so the count stays bounded.
    private var timers: [TimerSlot: Task<Void, Never>] = [:]

    /// Tasks this connection currently holds (bounded by 5). Read by tests.
    var trackedTaskCount: Int { timers.count + (receiveTask == nil ? 0 : 1) }

    private func after(_ slot: TimerSlot, _ duration: Duration, _ value: Input) {
        guard let input else { return }
        timers[slot]?.cancel()
        timers[slot] = (Task {
            guard (try? await Task.sleep(for: duration)) != nil else { return }
            input.yield(value)
        })
    }

    private func afterSleeper(_ slot: TimerSlot, _ duration: Duration, _ value: Input) {
        guard let input else { return }
        let sleeper = self.sleeper
        timers[slot]?.cancel()
        timers[slot] = (Task {
            guard (try? await Self.sleep(sleeper, for: duration)) != nil else { return }
            input.yield(value)
        })
    }

    private func send(_ text: String) async throws {
        guard let transport else { throw SendspinError.transport("not connected") }
        try await transport.send(text: text)
    }

    private func sendTime() async throws {
        let t1 = clock.nowMicros()
        pendingT1 = t1
        attempts += 1
        try await send(SendspinOutgoing.encode(SendspinClientTime(clientTransmitted: t1)))
        after(.timeReply, Self.timeReplyTimeout, .timeTimeout(t1))
    }

    private func startBurst() async throws {
        burst = SendspinClockBurst()
        attempts = 0
        try await sendTime()
    }

    private func exchangeDone() async throws {
        pendingT1 = nil
        timers[.timeReply]?.cancel()
        timers[.timeReply] = nil
        if attempts < burst.size { return try await sendTime() }
        clockState.finish(burst)
        if !clockState.isConverged {
            // Initial convergence needs two accepted samples: run bursts back to back until then.
            return try await startBurst()
        }
        if phase == .syncing {
            phase = .running
            available = true
            try await sendState()
            eventContinuation.yield(.synchronized)
        }
        afterSleeper(.burst, Self.burstInterval, .burstTick)
    }

    /// One connection, from the upgrade to the close. Returns the error and whether it got as far as `running`.
    private func runConnection(_ transport: any SendspinTransport) async -> (SendspinError?, Bool) {
        let (inbox, input) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
        self.input = input
        phase = .auth
        burst = SendspinClockBurst()
        attempts = 0
        pendingT1 = nil
        defer {
            receiveTask?.cancel()
            receiveTask = nil
            for task in timers.values { task.cancel() }
            timers = [:]
            input.finish()
            self.input = nil
        }
        do {
            try await transport.connect()
            receiveTask = (Task {
                while !Task.isCancelled {
                    do {
                        let frame = try await transport.receive()
                        input.yield(.frame(frame))
                        if case .closed = frame { return }
                    } catch {
                        input.yield(.failed(String(describing: error)))
                        return
                    }
                }
            })
            try await send(SendspinOutgoing.authFrame(token: configuration.token, clientID: configuration.clientID))
            after(.handshake, Self.handshakeTimeout, .deadline(.auth))

            for await item in inbox {
                if let outcome = try await handle(item) { return outcome }
            }
            return (.transport("closed"), phase == .running)
        } catch let error as SendspinError {
            return (error, phase == .running)
        } catch {
            return (.transport(String(describing: error)), phase == .running)
        }
    }

    /// Handles one inbox item; a non-nil result ends the connection.
    private func handle(_ item: Input) async throws -> (SendspinError?, Bool)? {
        switch item {
        case .failed(let detail):
            return (.transport(detail), phase == .running)
        case .frame(.closed(let code, let reason)):
            if code == Self.unauthorizedCloseCode { return (.unauthorized(reason), false) }
            if phase == .auth { return (.handshake("closed during auth"), false) }
            return (.transport("closed \(code.map(String.init) ?? "?")"), phase == .running)
        case .deadline(let which):
            if which == phase { return (.timeout(which == .auth ? "auth" : "server/hello"), false) }
        case .stateDeadline:
            if phase == .syncing && !available { try await sendState() }
        case .burstTick:
            if pendingT1 == nil { try await startBurst() }
        case .timeTimeout(let t1):
            if pendingT1 == t1 { try await exchangeDone() }
        case .frame(.binary(let data)):
            guard let chunk = try? SendspinWire.parseAudioChunk(data) else { return nil }
            if clockState.isConverged {
                eventContinuation.yield(.audio(chunk, localMicros: clockState.filter.computeClientTime(chunk.serverMicros)))
            } else {
                droppedChunks += 1
            }
        case .frame(.text(let text)):
            if phase == .auth {
                guard Self.isAuthOK(text) else { return (.handshake("unexpected auth reply"), false) }
                phase = .hello
                try await send(SendspinOutgoing.encode(configuration.hello))
                after(.handshake, Self.handshakeTimeout, .deadline(.hello))
                return nil
            }
            let message: SendspinIncoming
            do {
                message = try SendspinIncoming.decode(text)
            } catch {
                logger.error("Sendspin malformed message: \(String(describing: error), privacy: .public)")
                return nil
            }
            switch message {
            case .serverHello(let hello):
                guard phase == .hello else { return nil }
                guard hello.activeRoles.contains("player@v1") else { return (.roleRejected, false) }
                eventContinuation.yield(.connected(hello))
                phase = .syncing
                after(.stateDeadline, Self.unavailableStateAfter, .stateDeadline)
                try await startBurst()
            case .serverTime(let reply):
                guard let t1 = pendingT1, reply.clientTransmitted == t1 else { return nil }
                burst.add(SendspinClockSample(
                    t1: t1, t2: reply.serverReceived, t3: reply.serverTransmitted, t4: clock.nowMicros()))
                try await exchangeDone()
            case .streamStart(let start):
                if let format = start.player { eventContinuation.yield(.streamStarted(format)) }
            case .streamClear:
                eventContinuation.yield(.streamCleared)
            case .streamEnd:
                eventContinuation.yield(.streamEnded)
            case .groupUpdate(let update):
                eventContinuation.yield(.groupUpdated(update))
            case .serverCommand(let command):
                guard let player = command.player else { return nil }
                switch player.command {
                case .volume: if let value = player.volume { eventContinuation.yield(.setVolume(value)) }
                case .mute: if let value = player.mute { eventContinuation.yield(.setMute(value)) }
                case .setStaticDelay, .other: break
                }
            case .ignored:
                break
            }
        }
        return nil
    }

    private static func isAuthOK(_ text: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
        return object["type"] as? String == "auth_ok"
    }

    private func sendState() async throws {
        guard let transport else { return }
        let player = SendspinPlayerState(
            volume: volume, muted: muted,
            requiredLeadTimeMs: configuration.requiredLeadTimeMs, minBufferMs: configuration.minBufferMs)
        try await transport.send(text: SendspinOutgoing.encode(SendspinClientState(available: available, player: player)))
    }
}
