import Foundation
import MusicBackendKit
import os

/// One subscriber's view of one player: a first fetch, then events, polling and reconnect refetches together until
/// the task running `run()` is cancelled. Events are hints (#0076); the poll keeps the UI right if none decodes.
actor MANowPlayingWatch {
    private let client: MusicAssistantClient
    private let output: OutputDevice.ID
    private let clock: any Clock<Duration>
    private let policy: MANowPlayingPolicy
    private let yield: @Sendable (NowPlaying) -> Void
    private let cachePlayer: @Sendable (MAPlayer) async -> Void
    private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "MusicAssistantBackend")

    private var player: MAPlayer?
    private var queue: MAPlayerQueue?
    private var skew: Double = 0
    private var last: NowPlaying?
    private var appliedEvents = 0
    private var refetches = 0
    private var polls = 0
    private var refetchTask: Task<Void, Never>?

    private var playerID: String { output.rawValue }
    private var queueID: String { queue?.queueID ?? playerID }

    init(
        client: MusicAssistantClient, output: OutputDevice.ID, clock: any Clock<Duration>, policy: MANowPlayingPolicy,
        yield: @escaping @Sendable (NowPlaying) -> Void, cachePlayer: @escaping @Sendable (MAPlayer) async -> Void
    ) {
        self.client = client
        self.output = output
        self.clock = clock
        self.policy = policy
        self.yield = yield
        self.cachePlayer = cachePlayer
    }

    func run() async {
        // Subscribe before the first fetch so a change in between is not lost.
        let events = await client.events()
        let states = await client.states()
        if let serverTime = try? await client.call(.time()).doubleValue {
            skew = serverTime - Date().timeIntervalSince1970
        }
        await refetch()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await event in events { await self.handle(event) } }
            group.addTask { await self.pollLoop() }
            group.addTask {
                var lost = false
                for await state in states {
                    switch state {
                    case .reconnecting: lost = true
                    case .connected where lost:
                        lost = false
                        await self.refetch()
                    default: break
                    }
                }
            }
            await group.waitForAll()
        }
        refetchTask?.cancel()
        refetchTask = nil
        log.debug(
            "watch ended: \(self.appliedEvents, privacy: .public) events, \(self.refetches, privacy: .public) refetches, \(self.polls, privacy: .public) polls"
        )
    }

    // MARK: Events

    private func handle(_ event: MAServerEvent) async {
        guard !Task.isCancelled else { return }
        let action = MAEventMatch.classify(event, playerID: playerID, queueID: queueID)
        switch action {
        case .ignore:
            return
        case .refetch:
            log.debug("event \(event.event, privacy: .public): refetch")
            scheduleRefetch()
            return
        case .player(let updated):
            player = updated
            await cachePlayer(updated)
        case .queue(let updated):
            queue = updated
        case .elapsed(let seconds):
            let serverNow = Date().timeIntervalSince1970 + skew
            if queue != nil {
                queue?.elapsedTime = seconds
                queue?.elapsedTimeLastUpdated = serverNow
            } else {
                player?.elapsedTime = seconds
                player?.elapsedTimeLastUpdated = serverNow
            }
        }
        appliedEvents += 1
        log.debug("event \(event.event, privacy: .public) applied (\(self.appliedEvents, privacy: .public))")
        emit()
    }

    private func scheduleRefetch() {
        guard refetchTask == nil else { return }
        let clock = clock
        let delay = policy.refetchDebounce
        refetchTask = Task {
            do { try await clock.sleep(for: delay) } catch { return }
            await self.debouncedRefetch()
        }
    }

    private func debouncedRefetch() async {
        refetchTask = nil
        guard !Task.isCancelled else { return }
        await refetch()
    }

    // MARK: Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            let relaxed = appliedEvents > 0
            let before = appliedEvents
            do { try await clock.sleep(for: relaxed ? policy.relaxedPoll : policy.eagerPoll) } catch { return }
            // An event applied while relaxed sleeping restarts the relaxed wait instead of polling.
            if relaxed, appliedEvents != before { continue }
            polls += 1
            log.debug("poll \(self.polls, privacy: .public)")
            await refetch()
        }
    }

    // MARK: Fetching

    /// `players/get`, then the active queue (or the player's own queue when none is active). Failures keep the
    /// last snapshot; the next poll tries again.
    private func refetch() async {
        guard !Task.isCancelled else { return }
        refetches += 1
        do {
            let playerJSON = try await client.call(.player(id: playerID))
            guard !playerJSON.isNull else {
                player = nil
                queue = nil
                emit()
                return
            }
            let fetched = try playerJSON.decode(as: MAPlayer.self)
            var queueJSON = try await client.call(.activeQueue(playerID: playerID))
            if queueJSON.isNull { queueJSON = try await client.call(.queue(id: playerID)) }
            guard !Task.isCancelled else { return }
            player = fetched
            queue = queueJSON.isNull ? nil : try queueJSON.decode(as: MAPlayerQueue.self)
            await cachePlayer(fetched)
            emit()
        } catch {
            log.debug("refetch failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func emit() {
        guard !Task.isCancelled else { return }
        let now = Date()
        let snapshot = MANowPlayingMapper.snapshot(output: output, player: player, queue: queue, skew: skew, now: now)
        if let last, Self.same(last, snapshot, at: now) { return }
        last = snapshot
        yield(snapshot)
    }

    /// Equal apart from `updatedAt`, and within half a second of each other's position: a poll that restates the
    /// same position does not re-render.
    static func same(_ a: NowPlaying, _ b: NowPlaying, at now: Date) -> Bool {
        var x = a, y = b
        x.updatedAt = .distantPast
        y.updatedAt = .distantPast
        x.elapsed = 0
        y.elapsed = 0
        return x == y && abs(a.elapsed(at: now) - b.elapsed(at: now)) < 0.5
    }
}
