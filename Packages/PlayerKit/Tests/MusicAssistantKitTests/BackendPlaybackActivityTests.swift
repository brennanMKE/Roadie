import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `playbackActivity()` (#0121): `players/all` plus `player_queues/all` as `[OutputActivity]`, over the stub socket.
struct BackendPlaybackActivityTests {
    static let speakerID = SyntheticPlayback.playerID

    /// The synthetic player with its id, name and grouping fields overridden.
    static func player(
        id: String = speakerID, name: String? = nil, state: String = "playing", syncedTo: String? = nil,
        enabled: Bool = true, hidden: Bool = false, lastUpdated: Double? = nil
    ) throws -> MAJSON {
        guard case .object(var object) = try SyntheticPlayback.player(state: state) else { return .null }
        object["player_id"] = .string(id)
        if let name {
            object["name"] = .string(name)
            object["display_name"] = .string(name)
        }
        object["synced_to"] = syncedTo.map { .string($0) } ?? .null
        object["active_group"] = .null
        object["enabled"] = .bool(enabled)
        object["hide_in_ui"] = .bool(hidden)
        object["elapsed_time_last_updated"] = lastUpdated.map { .number($0) } ?? .null
        return .object(object)
    }

    static func queue(id: String = speakerID, state: String = "playing", lastUpdated: Double? = 1_000) throws -> MAJSON {
        guard case .object(var object) = try SyntheticPlayback.queue(state: state, lastUpdated: lastUpdated) else {
            return .null
        }
        object["queue_id"] = .string(id)
        return .object(object)
    }

    private func rig(players: [MAJSON], queues: [MAJSON]) async throws -> BackendRig {
        try await connectedBackend(
            script: controlScript {
                $0.override("players/all", result: .array(players))
                $0.override("player_queues/all", result: .array(queues))
            })
    }

    private func sent(_ transport: StubWebSocketTransport, _ command: String) -> Int {
        transport.sentRequests.filter { $0.command == command }.count
    }

    @Test func activityOnConnectListsPlayingPlayers() async throws {
        let rig = try await rig(players: [try Self.player()], queues: [try Self.queue(lastUpdated: 1_234)])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.isEmpty == false })
        let first = try #require(collector.items.last?.first)
        #expect(first.output == OutputDevice.ID(rawValue: Self.speakerID))
        #expect(first.state == .playing)
        #expect(first.leader == nil)
        #expect(first.updatedAt == 1_234)
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activityMapsOwnSendspinPlayerToThisMac() async throws {
        let rig = try await connectedBackend(
            script: controlScript {
                $0.override("players/all", result: try recordedResult(.playersAllSendspin))
            })
        await rig.backend.setLocalSendspinClientID(MusicAssistantThisMacTests.clientID)
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.isEmpty == false })
        let outputs = try #require(collector.items.last).map(\.output)
        #expect(outputs.contains(OutputDevice.thisMacID))
        #expect(!outputs.contains(OutputDevice.ID(rawValue: MusicAssistantThisMacTests.wrapperID)))
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activityMarksSyncedMembersWithTheirLeader() async throws {
        let rig = try await rig(
            players: [try Self.player(), try Self.player(id: "member", name: "Kitchen", state: "idle", syncedTo: Self.speakerID)],
            queues: [try Self.queue()])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.count == 2 })
        let member = try #require(collector.items.last?.first { $0.output.rawValue == "member" })
        #expect(member.leader == OutputDevice.ID(rawValue: Self.speakerID))
        #expect(member.name == "Kitchen")
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activitySkipsHiddenAndDisabledPlayers() async throws {
        let rig = try await rig(
            players: [
                try Self.player(), try Self.player(id: "hidden", hidden: true),
                try Self.player(id: "disabled", enabled: false),
            ],
            queues: [try Self.queue()])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.isEmpty == false })
        #expect(collector.items.last?.map(\.output.rawValue) == [Self.speakerID])
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activityRefreshesOnPlayerUpdatedEvent() async throws {
        let rig = try await rig(players: [try Self.player()], queues: [try Self.queue()])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.first?.state == .playing })
        // Another app paused it.
        rig.transport.script.override("players/all", result: .array([try Self.player(state: "paused")]))
        rig.transport.script.override("player_queues/all", result: .array([try Self.queue(state: "paused")]))
        try rig.transport.push(
            MAJSON.object([
                "event": "player_updated", "object_id": .string(Self.speakerID),
                "data": try Self.player(state: "paused"),
            ]).encodedString())
        #expect(await waitFor { rig.clock.hasSleeper(dueIn: .milliseconds(150)) })
        rig.clock.advance(by: .milliseconds(150))
        #expect(await waitFor { collector.items.last?.first?.state == .paused })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activityIgnoresQueueTimeUpdated() async throws {
        let rig = try await rig(players: [try Self.player()], queues: [try Self.queue()])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.isEmpty == false })
        let before = sent(rig.transport, "players/all")
        rig.transport.push(
            MAJSON.object(["event": "queue_time_updated", "object_id": .string(Self.speakerID), "data": 95])
                .encodedString())
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rig.clock.hasSleeper(dueIn: .milliseconds(150)))
        rig.clock.advance(by: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(100))
        #expect(sent(rig.transport, "players/all") == before)
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activityRefetchesAfterReconnect() async throws {
        let rig = try await rig(players: [try Self.player()], queues: [try Self.queue()])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.isEmpty == false })
        let client = try #require(await rig.backend.client)
        rig.transport.closeFromServer()
        #expect(await waitFor {
            if case .reconnecting = await client.state { return true }
            return false
        })
        rig.clock.advance(by: .seconds(2))
        #expect(await waitFor {
            rig.factory.transports.count == 2 && sent(rig.factory.transports[1], "players/all") >= 1
                && sent(rig.factory.transports[1], "player_queues/all") >= 1
        })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func activityIsEmptyWhileDisconnected() async throws {
        let idle = try makeBackend()
        let none = Collector(await idle.backend.playbackActivity())
        #expect(await waitFor { none.items == [[]] })
        #expect(idle.factory.made == 0)
        none.stop()

        let rig = try await rig(players: [try Self.player()], queues: [try Self.queue()])
        let collector = Collector(await rig.backend.playbackActivity())
        #expect(await waitFor { collector.items.last?.isEmpty == false })
        await rig.backend.disconnect()
        #expect(await waitFor { collector.items.last == [] })
        collector.stop()
    }
}
