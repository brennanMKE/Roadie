import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `nowPlaying(on:)` over the stub socket and a `ManualClock`. Event frames use the API page's documented shape
/// `{"event", "object_id", "data"}` (unrecorded, #0076) and the variants `MAEventMatch` accepts.
struct BackendNowPlayingTests {
    let output = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)

    /// A connected backend whose player and queue answer as playing.
    private func playingRig(_ change: (inout FixtureScript) throws -> Void = { _ in }) async throws -> BackendRig {
        try await connectedBackend(
            script: controlScript {
                $0.override("players/get", result: try SyntheticPlayback.player())
                $0.override("player_queues/get_active_queue", result: try SyntheticPlayback.queue())
                try change(&$0)
            })
    }

    private func gets(_ rig: BackendRig) -> Int {
        rig.factory.transports.flatMap(\.sentRequests).filter { $0.command == "players/get" }.count
    }

    /// The poll loop is asleep for `poll`, so the last refetch, including its queue calls, has finished.
    /// A bare sleeper count can't tell the poll sleeper from an in-flight call-timeout sleeper (#0088).
    private func settled(_ rig: BackendRig, poll: Duration = .seconds(1)) async -> Bool {
        await waitFor { rig.clock.hasSleeper(dueIn: poll) }
    }

    private func push(_ rig: BackendRig, _ event: MAJSON) {
        rig.transport.push(event.encodedString())
    }

    @Test func notConnectedYieldsIdleAndSendsNothing() async throws {
        let rig = try makeBackend()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(collector.items.first == .idle(on: output, at: collector.items[0].updatedAt))
        #expect(collector.items.first?.state == .stopped)
        #expect(rig.factory.made == 0)
        #expect(!collector.finished)
        collector.stop()
    }

    @Test func firstSnapshotComesFromPlayerAndQueue() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        let first = try #require(collector.items.first)
        #expect(first.state == .playing)
        #expect(first.title == "Synthetic Song")
        #expect(first.elapsed == 30)
        #expect(first.artwork == ArtworkRef("proxy123"))
        let commands = rig.transport.sentRequests.map(\.command)
        #expect(commands.contains("time"))
        #expect(commands.contains("player_queues/get_active_queue"))
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func pushedPlayerUpdatedChangesState() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(await settled(rig))
        try push(rig, ["event": "player_updated", "object_id": .string(SyntheticPlayback.playerID),
                   "data": try SyntheticPlayback.player(state: "paused")])
        #expect(await waitFor { collector.items.last?.state == .paused })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func pushedQueueTimeUpdatedMovesElapsed() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(await settled(rig))
        push(rig, ["event": "queue_time_updated", "object_id": .string(SyntheticPlayback.playerID), "data": 95])
        #expect(await waitFor { (collector.items.last?.elapsed ?? 0) >= 95 })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func garbledEventTriggersOneDebouncedRefetch() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(await settled(rig))
        let before = gets(rig)
        for _ in 0..<3 {
            push(rig, ["event": "player_updated", "object_id": .string(SyntheticPlayback.playerID), "data": "garbage"])
        }
        // The debounce sleeper is running.
        #expect(await waitFor { rig.clock.hasSleeper(dueIn: .milliseconds(150)) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(gets(rig) == before)
        rig.clock.advance(by: .milliseconds(150))
        #expect(await waitFor { gets(rig) == before + 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(gets(rig) == before + 1)
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func pollsEverySecondUntilAnEventApplies() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        for round in 1...3 {
            #expect(await settled(rig))
            let before = gets(rig)
            rig.clock.advance(by: .seconds(1))
            #expect(await waitFor { gets(rig) == before + 1 }, "poll \(round)")
        }
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func pollRelaxesToTenSecondsOnceEventsWork() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(await settled(rig))
        push(rig, ["event": "queue_time_updated", "object_id": .string(SyntheticPlayback.playerID), "data": 50])
        #expect(await waitFor { (collector.items.last?.elapsed ?? 0) >= 50 })
        // The eager sleep already running still polls once.
        var before = gets(rig)
        rig.clock.advance(by: .seconds(1))
        #expect(await waitFor { gets(rig) == before + 1 })
        #expect(await settled(rig, poll: .seconds(10)))
        before = gets(rig)
        rig.clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(gets(rig) == before)
        rig.clock.advance(by: .seconds(5))
        #expect(await waitFor { gets(rig) == before + 1 })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func pollPicksUpAnExternalPauseWithoutEvents() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.last?.state == .playing })
        #expect(await settled(rig))
        rig.transport.script.override("players/get", result: try SyntheticPlayback.player(state: "paused"))
        rig.clock.advance(by: .seconds(1))
        #expect(await waitFor { collector.items.last?.state == .paused })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func identicalPollsDoNotYield() async throws {
        let rig = try await connectedBackend(script: controlScript())
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        for _ in 0..<3 {
            #expect(await settled(rig))
            let before = gets(rig)
            rig.clock.advance(by: .seconds(1))
            #expect(await waitFor { gets(rig) == before + 1 })
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(collector.items.count == 1)
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func reconnectRefetchesAndKeepsTheStream() async throws {
        // The new socket answers with another title, so the reconnect refetch is seen finishing, not just sent
        // (#0149: a refetch still in flight when the event below lands would put "playing" back over "paused").
        let script = try controlScript {
            $0.override("players/get", result: try SyntheticPlayback.player())
            $0.override("player_queues/get_active_queue", result: try SyntheticPlayback.queue())
        }
        var reconnected = script
        reconnected.override("players/get", result: try SyntheticPlayback.player(title: "Reconnected Song"))
        let rig = try await connectedBackend(
            script: script, extraTransports: [StubWebSocketTransport(script: reconnected)])
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(await settled(rig))
        let client = try #require(await rig.backend.client)
        rig.transport.closeFromServer()
        #expect(await waitFor {
            if case .reconnecting = await client.state { return true }
            return false
        })
        // Past the first reconnect delay (1 s plus jitter); the watch refetches on the new socket once connected.
        // The same advance wakes the poll, which may refetch on either socket.
        rig.clock.advance(by: .seconds(2))
        #expect(await waitFor { rig.factory.made == 2 })
        #expect(await waitFor { collector.items.last?.title == "Reconnected Song" })
        #expect(collector.items.last?.state == .playing)
        // The poll is back asleep: no refetch is left in flight to race the event.
        #expect(await settled(rig))
        // The stream survived: an event on the new socket still reaches it.
        try rig.factory.transports[1].push(
            MAJSON.object([
                "event": "player_updated", "object_id": .string(SyntheticPlayback.playerID),
                "data": try SyntheticPlayback.player(state: "paused", title: "Reconnected Song"),
            ]).encodedString())
        #expect(await waitFor { collector.items.last?.state == .paused })
        #expect(!collector.finished)
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func disconnectYieldsIdleAndKeepsTheStreamOpen() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.last?.state == .playing })
        await rig.backend.disconnect()
        #expect(await waitFor { collector.items.last?.state == .stopped })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!collector.finished)
        collector.stop()
    }

    @Test func cancellingTheStreamStopsPollingAndEvents() async throws {
        let rig = try await playingRig()
        let collector = Collector(await rig.backend.nowPlaying(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(await settled(rig))
        collector.stop()
        // Only the client's ping loop is left on the clock.
        #expect(await waitFor { rig.clock.sleeperCount == 1 })
        let sent = rig.transport.sentRequests.count
        push(rig, ["event": "player_updated", "object_id": .string(SyntheticPlayback.playerID), "data": "garbage"])
        for _ in 0..<5 { rig.clock.advance(by: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.transport.sentRequests.count == sent)
        await rig.backend.disconnect()
    }

    @Test func twoSubscribersOnDifferentPlayersStaySeparate() async throws {
        let other = "other-player"
        let rig = try await playingRig { script in
            guard case .object(var object) = try SyntheticPlayback.player(title: "Other Song") else { return }
            object["player_id"] = .string(other)
            script.routes.insert(
                .result(command: "players/get", matches: { $0["player_id"] == .string(other) }, .object(object)), at: 0)
        }
        let first = Collector(await rig.backend.nowPlaying(on: output))
        let second = Collector(await rig.backend.nowPlaying(on: OutputDevice.ID(rawValue: other)))
        #expect(await waitFor { first.items.count == 1 && second.items.count == 1 })
        #expect(first.items[0].title == "Synthetic Song")
        #expect(second.items[0].title == "Other Song")
        try push(rig, ["event": "player_updated", "object_id": .string(other),
                   "data": try SyntheticPlayback.player(state: "paused", title: "Other Song")])
        #expect(await waitFor { second.items.last?.state == .paused })
        try await Task.sleep(for: .milliseconds(50))
        #expect(first.items.allSatisfy { $0.state == .playing })
        first.stop()
        second.stop()
        await rig.backend.disconnect()
    }
}
