import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `queue(on:)` over the stub socket and a `ManualClock` (#0144). Most queue items are SYNTHETIC (the baseline
/// `player-queue-items.json` is empty), shaped after the `QueueItem` schema in `docs/ma-protocol/openapi.json`, and
/// carry the real server's `"index": 0` by default (#0187). The `--record-queue` recording (#0196) drives
/// `queueRowsFromTheRecordedLoadedQueueAreNumberedByPosition` once it exists.
struct BackendQueueTests {
    let output = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)
    static let queueID = SyntheticPlayback.playerID

    static func trackJSON(_ n: Int, artist: String?) -> MAJSON {
        var track: [String: MAJSON] = [
            "item_id": .string("\(n)"), "provider": "library", "name": .string("Song \(n)"),
            "uri": .string("library://track/\(n)"), "media_type": "track", "duration": 100,
            "album": ["item_id": "5", "provider": "library", "name": "Album", "uri": "library://album/5"],
        ]
        if let artist {
            track["artists"] = [["item_id": "9", "provider": "library", "name": .string(artist), "uri": "library://artist/9"]]
        }
        return .object(track)
    }

    /// `serverIndex` is the item's `index` field; Music Assistant sends its default, 0, on every item (#0187), so that
    /// is the default here. nil numbers the item by its position.
    static func itemJSON(_ n: Int, artist: String? = "Artist", serverIndex: Int? = 0) -> MAJSON {
        [
            "queue_id": .string(queueID), "queue_item_id": .string("qi\(n)"),
            "name": .string(artist.map { "\($0) - Song \(n)" } ?? "Song \(n)"), "duration": 100,
            "index": .number(Double(serverIndex ?? n)), "available": true, "media_item": trackJSON(n, artist: artist),
        ]
    }

    static func queueJSON(items: Int, current: Int) -> MAJSON {
        ["queue_id": .string(queueID), "active": true, "items": .number(Double(items)), "current_index": .number(Double(current))]
    }

    /// A connected backend whose queue has `count` items, answered `pageSize` at a time by offset.
    private func rig(count: Int, pageSize: Int, serverIndex: Int? = 0) async throws -> BackendRig {
        let rig = try await connectedBackend(
            script: controlScript { script in
                script.override("player_queues/get_active_queue", result: Self.queueJSON(items: count, current: 1))
                script.override("player_queues/get", result: Self.queueJSON(items: count, current: 1))
                for offset in stride(from: 0, to: count, by: pageSize) {
                    let page = MAJSON.array((offset..<min(offset + pageSize, count)).map { Self.itemJSON($0, serverIndex: serverIndex) })
                    script.routes.insert(
                        .result(command: "player_queues/items", matches: { $0["offset"]?.intValue == offset }, page),
                        at: 0)
                }
            })
        await rig.backend.setQueuePolicy(MAQueuePolicy(pageSize: pageSize))
        return rig
    }

    private func queueGets(_ rig: BackendRig) -> Int {
        rig.transport.sentRequests.filter { $0.command == "player_queues/get" }.count
    }

    @Test func queueSnapshotPagesItems() async throws {
        let rig = try await rig(count: 3, pageSize: 2)
        let collector = Collector(await rig.backend.queue(on: output))
        #expect(await waitFor { collector.items.last?.isComplete == true && collector.items.last?.items.count == 3 })
        let last = try #require(collector.items.last)
        #expect(last.items.map(\.id) == ["qi0", "qi1", "qi2"])
        #expect(last.currentIndex == 1)
        #expect(last.total == 3)
        #expect(last.items[0].artist == "Artist")
        #expect(last.items[0].title == "Song 0")
        #expect(last.items[0].album == "Album")
        #expect(last.items[0].item == MediaID(.track, "library://track/0"))
        // The first page showed before the second arrived.
        #expect(collector.items.contains { $0.items.count == 2 && !$0.isComplete })
        let offsets = rig.transport.sentRequests.filter { $0.command == "player_queues/items" }
            .compactMap { $0.args["offset"]?.intValue }
        #expect(offsets == [0, 2])
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func queueRowsUsePositionWhenTheServerSendsIndexZero() async throws {
        let rig = try await rig(count: 5, pageSize: 2, serverIndex: 0)
        let collector = Collector(await rig.backend.queue(on: output))
        #expect(await waitFor { collector.items.last?.isComplete == true && collector.items.last?.items.count == 5 })
        let last = try #require(collector.items.last)
        #expect(last.items.map(\.index) == [0, 1, 2, 3, 4])
        #expect(last.items.map(\.id) == ["qi0", "qi1", "qi2", "qi3", "qi4"])
        collector.stop()
        await rig.backend.disconnect()
    }

    /// The recorded loaded queue (#0196), routed by `FixtureScript.recorded` at 50 rows a page. Skipped until recorded.
    @Test(
        .enabled(
            if: MAFixture.playerQueueItemsLoaded.isRecorded && MAFixture.playerQueueGetLoaded.isRecorded
                && MAFixture.playersAllPlaying.isRecorded))
    func queueRowsFromTheRecordedLoadedQueueAreNumberedByPosition() async throws {
        let queue = try recordedResult(.playerQueueGetLoaded)
        let queueID = try #require(queue["queue_id"]?.stringValue)
        let current = try #require(queue["current_index"]?.intValue)
        var rows = try MAFixture.playerQueueItemsLoaded.frames().flatMap { $0["result"]?.arrayValue ?? [] }
        if MAFixture.playerQueueItemsPage2.isRecorded {
            rows += try MAFixture.playerQueueItemsPage2.frames().flatMap { $0["result"]?.arrayValue ?? [] }
        }
        // As `MAQueueWatch.item`: the track's name when it has an artist, else the row's own name.
        let titles = rows.map { row -> String in
            let track = row["media_item"]
            let hasArtist = !(track?["artists"]?.arrayValue?.first?["name"]?.stringValue ?? "").isEmpty
            let trackName = track?["name"]?.stringValue
            return (hasArtist ? trackName : row["name"]?.stringValue ?? trackName) ?? ""
        }
        let count = rows.count
        var answered = queue
        if case .object(var object) = answered {
            object["items"] = .number(Double(count))
            answered = .object(object)
        }
        let queueAnswer = answered
        // The recorded queue belongs to a player (a sync group, `syncgroup_…`) that only the same run's `players/all`
        // lists; the baseline `players-all` predates it, and `players/get` answers only the baseline player. So the
        // rig answers `players/all` with `players-all-playing` and lists outputs first, as the app does before the
        // user picks one: the queue's player resolves from that list.
        let playersRoute = try FixtureScript.Route.fixture(.playersAllPlaying)
        let rig = try await connectedBackend(
            script: controlScript { script in
                script.routes.insert(playersRoute, at: 0)
                script.override("player_queues/get_active_queue", result: queueAnswer)
                script.override("player_queues/get", result: queueAnswer)
            })
        await rig.backend.setQueuePolicy(MAQueuePolicy(pageSize: 50))
        let outputs = try await rig.backend.outputs()
        #expect(outputs.contains { $0.id.rawValue == queueID })
        let collector = Collector(await rig.backend.queue(on: OutputDevice.ID(rawValue: queueID)))
        #expect(await waitFor { collector.items.last?.isComplete == true && collector.items.last?.items.count == count })
        let last = try #require(collector.items.last)
        #expect(last.items.map(\.index) == Array(0..<count))
        #expect(last.currentIndex == current)
        #expect(last.items.map(\.title) == titles)
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func queueRefetchesOnItsOwnQueueEventsOnly() async throws {
        let rig = try await rig(count: 1, pageSize: 500)
        let collector = Collector(await rig.backend.queue(on: output))
        #expect(await waitFor { collector.items.last?.items.count == 1 })
        #expect(await waitFor { rig.clock.hasSleeper(dueIn: .seconds(30)) })
        let before = queueGets(rig)
        rig.transport.push(
            (["event": "queue_items_updated", "object_id": "someone_else", "data": Self.queueJSON(items: 1, current: 0)]
                as MAJSON).encodedString())
        try await Task.sleep(for: .milliseconds(50))
        #expect(!rig.clock.hasSleeper(dueIn: .milliseconds(150)))
        rig.transport.push(
            (["event": "queue_items_updated", "object_id": .string(Self.queueID), "data": Self.queueJSON(items: 1, current: 0)]
                as MAJSON).encodedString())
        #expect(await waitFor { rig.clock.hasSleeper(dueIn: .milliseconds(150)) })
        #expect(queueGets(rig) == before)
        rig.clock.advance(by: .milliseconds(150))
        #expect(await waitFor { queueGets(rig) == before + 1 })
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func notConnectedQueueIsEmpty() async throws {
        let rig = try makeBackend()
        let collector = Collector(await rig.backend.queue(on: output))
        #expect(await waitFor { collector.items.count == 1 })
        #expect(collector.items.first == .empty(on: output))
        #expect(rig.factory.made == 0)
        collector.stop()
    }
}

extension ModelDecodingTests {
    @Test func queueItemDecodesItsTrack() throws {
        let item = try BackendQueueTests.itemJSON(4, serverIndex: 4).decode(as: MAQueueItem.self)
        let track = try #require(item.track)
        #expect(track.name == "Song 4")
        #expect(track.artists?.first?.name == "Artist")
        let row = MAQueueWatch.item(item, position: 4)
        #expect(row.id == "qi4")
        #expect(row.index == 4)
        // The item's JSON says 4; the position wins (#0187).
        #expect(MAQueueWatch.item(item, position: 2).index == 2)
        #expect(row.artist == "Artist")
        #expect(row.duration == 100)
        // A media item that isn't a track (no uri) leaves the row on the queue item's own name.
        let radio = try (["queue_item_id": "r", "name": "Radio One", "media_item": ["name": "Radio One"]] as MAJSON)
            .decode(as: MAQueueItem.self)
        #expect(radio.track == nil)
        #expect(MAQueueWatch.item(radio, position: 7).title == "Radio One")
        #expect(MAQueueWatch.item(radio, position: 7).index == 7)
    }
}

/// Removes, moves and clear on a Music Assistant queue (#0145). Queue items are synthetic, as above.
extension BackendQueueTests {
    private func editRig(_ extra: [FixtureScript.Route] = []) async throws -> BackendRig {
        try await connectedBackend(
            script: controlScript { script in
                script.override("player_queues/get_active_queue", result: Self.queueJSON(items: 5, current: 0))
                script.override("player_queues/get", result: Self.queueJSON(items: 5, current: 0))
                for command in [
                    "player_queues/delete_item", "player_queues/move_item", "player_queues/clear",
                    "player_queues/play_index",
                ] {
                    script.routes.insert(.result(command: command, .null), at: 0)
                }
                for route in extra { script.routes.insert(route, at: 0) }
            })
    }

    private func sent(_ rig: BackendRig, _ command: String) -> [SentRequest] {
        rig.transport.sentRequests.filter { $0.command == command }
    }

    @Test func deleteSendsOnePerRowHighestFirst() async throws {
        let rig = try await editRig()
        let items = [1, 4, 2].map { RemoteQueueItem(id: "qi\($0)", index: $0, title: "Song \($0)") }
        try await rig.backend.edit(.remove(items: items), on: output)
        let deletes = sent(rig, "player_queues/delete_item")
        #expect(deletes.compactMap { $0.args["item_id_or_index"]?.stringValue } == ["qi4", "qi2", "qi1"])
        #expect(deletes.allSatisfy { $0.args["queue_id"]?.stringValue == Self.queueID })
        await rig.backend.disconnect()
    }

    @Test func playIndexSendsTheRowPosition() async throws {
        let rig = try await editRig()
        try await rig.backend.edit(.play(index: 3), on: output)
        let plays = sent(rig, "player_queues/play_index")
        #expect(plays.count == 1)
        #expect(plays.first?.args["index"]?.intValue == 3)
        #expect(plays.first?.args["queue_id"]?.stringValue == Self.queueID)
        await rig.backend.disconnect()
    }

    @Test func moveSendsPosShift() async throws {
        let rig = try await editRig()
        try await rig.backend.edit(.move(itemID: "qi3", shift: -2), on: output)
        let move = try #require(sent(rig, "player_queues/move_item").first)
        #expect(move.args["queue_item_id"]?.stringValue == "qi3")
        #expect(move.args["pos_shift"]?.intValue == -2)
        #expect(move.args["queue_id"]?.stringValue == Self.queueID)
        await rig.backend.disconnect()
    }

    @Test func clearUsesQueueClear() async throws {
        let rig = try await editRig()
        try await rig.backend.edit(.clear, on: output)
        #expect(sent(rig, "player_queues/clear").map { $0.args["queue_id"]?.stringValue } == [Self.queueID])
        #expect(sent(rig, "player_queues/delete_item").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func bufferedRefusalIsAClearError() async throws {
        let rig = try await editRig([
            .error(command: "player_queues/move_item", code: 999, details: "IndexError: Item is already buffered")
        ])
        await #expect(throws: QueueEditError.buffered) {
            try await rig.backend.edit(.move(itemID: "qi0", shift: 1), on: output)
        }
        #expect(QueueEditError.buffered.errorDescription == "Track already buffered")
        await rig.backend.disconnect()
    }
}
