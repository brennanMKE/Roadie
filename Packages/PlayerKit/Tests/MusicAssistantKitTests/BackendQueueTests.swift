import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// `queue(on:)` over the stub socket and a `ManualClock` (#0144). The queue items are SYNTHETIC (the recorded
/// `player-queue-items.json` is empty), shaped after the `QueueItem` schema in `docs/ma-protocol/openapi.json`.
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

    static func itemJSON(_ n: Int, artist: String? = "Artist") -> MAJSON {
        [
            "queue_id": .string(queueID), "queue_item_id": .string("qi\(n)"),
            "name": .string(artist.map { "\($0) - Song \(n)" } ?? "Song \(n)"), "duration": 100,
            "index": .number(Double(n)), "available": true, "media_item": trackJSON(n, artist: artist),
        ]
    }

    static func queueJSON(items: Int, current: Int) -> MAJSON {
        ["queue_id": .string(queueID), "active": true, "items": .number(Double(items)), "current_index": .number(Double(current))]
    }

    /// A connected backend whose queue has `count` items, answered `pageSize` at a time by offset.
    private func rig(count: Int, pageSize: Int) async throws -> BackendRig {
        let rig = try await connectedBackend(
            script: controlScript { script in
                script.override("player_queues/get_active_queue", result: Self.queueJSON(items: count, current: 1))
                script.override("player_queues/get", result: Self.queueJSON(items: count, current: 1))
                for offset in stride(from: 0, to: count, by: pageSize) {
                    let page = MAJSON.array((offset..<min(offset + pageSize, count)).map { Self.itemJSON($0) })
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
        let item = try BackendQueueTests.itemJSON(4).decode(as: MAQueueItem.self)
        let track = try #require(item.track)
        #expect(track.name == "Song 4")
        #expect(track.artists?.first?.name == "Artist")
        let row = MAQueueWatch.item(item, fallbackIndex: 0)
        #expect(row.id == "qi4")
        #expect(row.index == 4)
        #expect(row.artist == "Artist")
        #expect(row.duration == 100)
        // A media item that isn't a track (no uri) leaves the row on the queue item's own name.
        let radio = try (["queue_item_id": "r", "name": "Radio One", "media_item": ["name": "Radio One"]] as MAJSON)
            .decode(as: MAQueueItem.self)
        #expect(radio.track == nil)
        #expect(MAQueueWatch.item(radio, fallbackIndex: 7).title == "Radio One")
        #expect(MAQueueWatch.item(radio, fallbackIndex: 7).index == 7)
    }
}
