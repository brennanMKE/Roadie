import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `ScriptedMusicAssistant` (#0197) through `MusicAssistantBackend`, as the app drives it.
struct ScriptedMusicAssistantTests {
    let speaker = OutputDevice.ID(rawValue: ScriptedMusicAssistant.speakerID)
    let queueID = ScriptedMusicAssistant.speakerID

    struct Rig {
        var backend: MusicAssistantBackend
        var server: ScriptedMusicAssistant
        var clock: ManualClock
    }

    /// A backend over the scripted server's transports, both on one `ManualClock`.
    private func scripted(_ scenario: ScriptedMusicAssistant.Scenario, connect: Bool = true) async throws -> Rig {
        let clock = ManualClock()
        let server = try ScriptedMusicAssistant(scenario: scenario, clock: clock)
        let factory = ScriptedTransportFactory(server: server)
        let backend = MusicAssistantBackend(
            address: { testAddress }, token: { _ in testToken }, transports: factory, http: factory.http, clock: clock)
        if connect { try await backend.connect() }
        return Rig(backend: backend, server: server, clock: clock)
    }

    private func lastEvent(_ rig: Rig, _ name: String) -> MAServerEvent? {
        rig.server.pushedEvents.last { $0.event == name }
    }

    @Test func queueLoadedRowsHaveIndexZeroAndPositionsFromPaging() async throws {
        let rig = try await scripted(.queueLoaded)
        let queue = try #require(rig.server.queue(for: queueID))
        let count = queue.items.count
        #expect(count > 3)
        #expect(queue.items.allSatisfy { $0["index"]?.intValue == 0 })
        await rig.backend.setQueuePolicy(MAQueuePolicy(pageSize: 5))
        let collector = Collector(await rig.backend.queue(on: speaker))
        #expect(await waitFor { collector.items.last?.isComplete == true && collector.items.last?.items.count == count })
        let last = try #require(collector.items.last)
        #expect(last.items.map(\.index) == Array(0..<count))
        #expect(last.items.map(\.id) == queue.itemIDs)
        #expect(last.currentIndex == 2)
        let offsets = rig.server.receivedCommands.filter { $0.command == "player_queues/items" }.compactMap { $0.args["offset"]?.intValue }
        #expect(offsets == Array(stride(from: 0, to: count, by: 5)))
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func playIndexMovesTheCurrentRowAndPushesAnEvent() async throws {
        let rig = try await scripted(.queueLoaded)
        try await rig.backend.edit(.play(index: 3), on: speaker)
        #expect(rig.server.queue(for: queueID)?.currentIndex == 3)
        #expect(rig.server.queue(for: queueID)?.state == "playing")
        let event = try #require(lastEvent(rig, "queue_updated"))
        #expect(event.objectID == queueID)
        #expect(event.data["current_index"]?.intValue == 3)
        let sent = try #require(rig.server.receivedCommands.last { $0.command.hasPrefix("player_queues/play") })
        #expect(sent.command == "player_queues/play_index")
        #expect(sent.args["index"]?.intValue == 3)
        #expect(rig.server.recentCommandSummaries().contains("play_index index=3"))
        // The client got the event too.
        let client = try #require(await rig.backend.client)
        let events = Collector(await client.events())
        rig.server.push(MAServerEvent(event: "queue_updated", objectID: queueID, data: ["current_index": 3]))
        #expect(await waitFor { events.items.contains { $0.event == "queue_updated" } })
        events.stop()
        await rig.backend.disconnect()
    }

    @Test func playMediaReplaceExpandsAnAlbum() async throws {
        let rig = try await scripted(.libraryIdle)
        let albumID = try #require(MAFixture.albumTracks.args?["item_id"]?.stringValue)
        let album = MediaID(.album, "library://album/\(albumID)")
        let albumTracks = try recordedResult(.albumTracks).arrayValue ?? []
        #expect(!albumTracks.isEmpty)
        try await rig.backend.play([album], on: speaker, mode: .replace())
        var queue = try #require(rig.server.queue(for: queueID))
        #expect(queue.items.map { $0["media_item"]?["uri"] } == albumTracks.map { $0["uri"] })
        #expect(queue.currentIndex == 0)
        #expect(queue.state == "playing")

        let tracks = try recordedResult(.tracksPage).arrayValue ?? []
        let first = try #require(tracks.first?["uri"]?.stringValue)
        let second = try #require(tracks.dropFirst().first?["uri"]?.stringValue)
        try await rig.backend.play([MediaID(.track, first)], on: speaker, mode: .append)
        try await rig.backend.play([MediaID(.track, second)], on: speaker, mode: .next)
        queue = try #require(rig.server.queue(for: queueID))
        let uris = queue.items.compactMap { $0["media_item"]?["uri"]?.stringValue }
        #expect(uris.count == albumTracks.count + 2)
        #expect(uris[1] == second)
        #expect(uris.last == first)
        #expect(lastEvent(rig, "queue_items_updated")?.data["items"]?.intValue == uris.count)
        await rig.backend.disconnect()
    }

    @Test func deleteAndMoveUpdateTheQueue() async throws {
        let rig = try await scripted(.queueLoaded)
        let collector = Collector(await rig.backend.queue(on: speaker))
        #expect(await waitFor { collector.items.last?.isComplete == true })
        let snapshot = try #require(collector.items.last)
        let ids = snapshot.items.map(\.id)
        let eventsBefore = rig.server.pushedEvents.count

        try await rig.backend.edit(.remove(items: [snapshot.items[1]]), on: speaker)
        var expected = ids
        expected.remove(at: 1)
        #expect(rig.server.queue(for: queueID)?.itemIDs == expected)

        let moved = expected[3]
        try await rig.backend.edit(.move(itemID: moved, shift: -2), on: speaker)
        expected.remove(at: 3)
        expected.insert(moved, at: 1)
        #expect(rig.server.queue(for: queueID)?.itemIDs == expected)
        #expect(rig.server.pushedEvents.dropFirst(eventsBefore).filter { $0.event == "queue_items_updated" }.count == 2)

        // The watch refetches on the pushed events and shows the new order.
        rig.clock.advance(by: .seconds(1))
        #expect(await waitFor {
            rig.clock.advance(by: .milliseconds(200))
            return collector.items.last?.items.map(\.id) == expected
        })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func transportCommandsChangeThePlayerState() async throws {
        let rig = try await scripted(.queueLoaded)
        try await rig.backend.transport(.pause, on: speaker)
        let paused = try #require(lastEvent(rig, "player_updated"))
        #expect(paused.objectID == queueID)
        #expect(paused.data["playback_state"]?.stringValue == "paused")
        #expect(rig.server.queue(for: queueID)?.state == "paused")

        try await rig.backend.transport(.setVolume(0.4), on: speaker)
        let volume = try #require(rig.server.receivedCommands.last { $0.command == "players/cmd/volume_set" })
        #expect(volume.args["volume_level"]?.intValue == 40)
        #expect(lastEvent(rig, "player_updated")?.data["volume_level"]?.intValue == 40)
        #expect(rig.server.player(queueID)?["volume_level"]?.intValue == 40)

        try await rig.backend.transport(.play, on: speaker)
        #expect(lastEvent(rig, "player_updated")?.data["playback_state"]?.stringValue == "playing")
        await rig.backend.disconnect()
    }

    @Test func favoritesAndPlaylistsAreApplied() async throws {
        let rig = try await scripted(.libraryIdle)
        let tracks = try recordedResult(.tracksPage).arrayValue ?? []
        let uri = try #require(tracks.first?["uri"]?.stringValue)
        let track = MediaID(.track, uri)

        try await rig.backend.setFavorite(track, true)
        #expect(try await rig.backend.favoriteTracks(page: PageRequest()).items.map(\.id) == [track])
        #expect(try await rig.backend.favoriteCount(.track) == 1)
        try await rig.backend.setFavorite(track, false)
        #expect(try await rig.backend.favoriteTracks(page: PageRequest()).items.isEmpty)

        let before = try await rig.backend.playlists(page: PageRequest()).items.count
        let created = try await rig.backend.createPlaylist(named: "Road Trip")
        #expect(created.name == "Road Trip")
        try await rig.backend.add([track], toPlaylist: created.id)
        #expect(try await rig.backend.tracks(ofPlaylist: created.id).map(\.id) == [track])
        let listed = try await rig.backend.playlists(page: PageRequest()).items
        #expect(listed.count == before + 1)
        #expect(listed.contains { $0.id == created.id && $0.name == "Road Trip" })

        try await rig.backend.renamePlaylist(created.id, to: "Night Drive")
        #expect(try await rig.backend.playlists(page: PageRequest()).items.contains { $0.name == "Night Drive" })
        try await rig.backend.remove(positions: [1], fromPlaylist: created.id)
        #expect(try await rig.backend.tracks(ofPlaylist: created.id).isEmpty)
        try await rig.backend.deletePlaylist(created.id)
        #expect(try await rig.backend.playlists(page: PageRequest()).items.count == before)
        await rig.backend.disconnect()
    }

    @Test func unreachableScenarioFailsToConnect() async throws {
        let rig = try await scripted(.unreachable, connect: false)
        do {
            try await rig.backend.connect()
            Issue.record("expected unreachable")
        } catch let error as MusicBackendError {
            guard case .unreachable = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        #expect(rig.server.receivedCommands.isEmpty)
    }

    @Test func badTokenScenarioReturnsTheRecordedAuthError() async throws {
        let rig = try await scripted(.badToken, connect: false)
        await #expect(throws: (any Error).self) { try await rig.backend.connect() }
        let auth = try #require(rig.server.receivedCommands.first { $0.command == "auth" })
        #expect(auth.args["token"]?.stringValue == "redacted")
        // The recorded error-auth frame went back, with the request's message id.
        let recorded = try #require(try MAFixture.errorAuth.frames().first)
        let sent = rig.server.script.replies(command: "auth", args: ["token": "x"], messageID: "m1")
        let reply = try MAJSON.parse(try #require(sent.first))
        #expect(reply["error_code"] == recorded["error_code"])
        #expect(reply["details"] == recorded["details"])
        #expect(!rig.server.receivedCommands.contains { $0.command == "players/all" })
    }

    private func keys(_ json: MAJSON) -> Set<String> { Set(json.objectValue.map { Array($0.keys) } ?? []) }

    @Test func repliesKeepRecordedShapes() async throws {
        let server = try ScriptedMusicAssistant(scenario: .queueLoaded, clock: ManualClock())
        let script = server.script
        func result(_ command: String, _ args: MAJSON = [:]) throws -> MAJSON {
            let text = try #require(script.replies(command: command, args: args, messageID: "1").first)
            let frame = try MAJSON.parse(text)
            #expect(frame["error_code"] == nil, "\(command)")
            return frame["result"] ?? .null
        }
        let players = try result("players/all").decode(as: [MAPlayer].self)
        #expect(players.contains { $0.playerID == queueID && $0.state == .playing })
        _ = try result("players/get", ["player_id": .string(queueID)]).decode(as: MAPlayer.self)
        _ = try result("player_queues/all").decode(as: [MAPlayerQueue].self)
        let queue = try result("player_queues/get", ["queue_id": .string(queueID)]).decode(as: MAPlayerQueue.self)
        #expect(queue.currentIndex == 2)
        #expect(queue.currentItem != nil)
        _ = try result("player_queues/get_active_queue", ["player_id": .string(queueID)]).decode(as: MAPlayerQueue.self)
        let items = try result("player_queues/items", ["queue_id": .string(queueID), "limit": 500, "offset": 0])
        let decoded = try items.decode(as: [MAQueueItem].self)
        #expect(decoded.count == queue.items)
        #expect(decoded.allSatisfy { $0.index == 0 })

        // Same keys as the recordings.
        let recordedQueue = try recordedResult(.playerQueueGet)
        let builtQueue = try result("player_queues/get", ["queue_id": .string(queueID)])
        #expect(keys(builtQueue) == keys(recordedQueue))
        if MAFixture.playerQueueItemsLoaded.isRecorded {
            let recordedRow = try #require(try MAFixture.playerQueueItemsLoaded.frames().first?["result"]?[0])
            let tracks = try recordedResult(.tracksPage).arrayValue ?? []
            let uri = try #require(tracks.first?["uri"]?.stringValue)
            _ = try result("player_queues/play_media", ["queue_id": .string(queueID), "media": [.string(uri)], "option": "add"])
            let rows = try result("player_queues/items", ["queue_id": .string(queueID), "limit": 500, "offset": 0]).arrayValue ?? []
            let built = try #require(rows.last)
            #expect(keys(built) == keys(recordedRow))
            _ = try built.decode(as: MAQueueItem.self)
        }
        // Event payloads decode too.
        _ = try result("players/cmd/pause", ["player_id": .string(queueID)])
        for event in server.pushedEvents {
            switch event.event {
            case "player_updated": _ = try event.data.decode(as: MAPlayer.self)
            default: _ = try event.data.decode(as: MAPlayerQueue.self)
            }
        }
        #expect(!server.pushedEvents.isEmpty)
    }
}
