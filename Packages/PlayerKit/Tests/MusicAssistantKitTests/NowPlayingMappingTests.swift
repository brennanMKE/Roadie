import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// Synthetic playing frames (#0076 has not recorded one) mapped to `NowPlaying`.
struct NowPlayingMappingTests {
    let output = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func player(_ json: MAJSON) throws -> MAPlayer { try json.decode(as: MAPlayer.self) }
    private func queue(_ json: MAJSON) throws -> MAPlayerQueue { try json.decode(as: MAPlayerQueue.self) }

    @Test func playingPlayerMapsTitleArtistAlbumDuration() throws {
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player()), queue: nil, skew: 0, now: now)
        #expect(snapshot.state == .playing)
        #expect(snapshot.title == "Synthetic Song")
        #expect(snapshot.artist == "Synthetic Artist")
        #expect(snapshot.album == "Synthetic Album")
        #expect(snapshot.duration == 200)
        #expect(snapshot.item == MediaID(.track, "library://track/7"))
        #expect(snapshot.volume == 0.2)
        #expect(snapshot.output == output)
    }

    @Test(arguments: [
        ("playing", NowPlaying.State.playing), ("paused", .paused), ("idle", .stopped), ("buffering", .stopped),
    ])
    func stateMapping(raw: String, expected: NowPlaying.State) throws {
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player(state: raw)), queue: nil, skew: 0, now: now)
        #expect(snapshot.state == expected)
    }

    @Test func unknownPlayerStateFallsBackToTheQueue() throws {
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player(state: "buffering")),
            queue: try queue(SyntheticPlayback.queue(state: "paused")), skew: 0, now: now)
        #expect(snapshot.state == .paused)
    }

    @Test func elapsedUsesQueueTimestampCorrectedForSkew() throws {
        // The server clock is 500 s ahead; its timestamp ten seconds before its own now is ten seconds before `now`.
        let serverNow = now.timeIntervalSince1970 + 500
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player()),
            queue: try queue(SyntheticPlayback.queue(elapsed: 30, lastUpdated: serverNow - 10)), skew: 500, now: now)
        #expect(snapshot.elapsed == 30)
        #expect(snapshot.updatedAt == now.addingTimeInterval(-10))
        #expect(abs(snapshot.elapsed(at: now) - 40) < 0.001)
    }

    @Test func implausibleTimestampFallsBackToNow() throws {
        for lastUpdated in [now.timeIntervalSince1970 + 3600, now.timeIntervalSince1970 - 3 * 86_400] {
            let snapshot = MANowPlayingMapper.snapshot(
                output: output, player: try player(SyntheticPlayback.player()),
                queue: try queue(SyntheticPlayback.queue(elapsed: 12, lastUpdated: lastUpdated)), skew: 0, now: now)
            #expect(snapshot.updatedAt == now)
            #expect(snapshot.elapsed == 12)
        }
        let missing = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player()),
            queue: try queue(SyntheticPlayback.queue(elapsed: 12, lastUpdated: nil)), skew: 0, now: now)
        #expect(missing.updatedAt == now)
    }

    @Test func artworkRefComesFromImageURLProxyID() throws {
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player()), queue: nil, skew: 0, now: now)
        #expect(snapshot.artwork == ArtworkRef("proxy123"))
        #expect(MANowPlayingMapper.proxyID(imageURL: "http://elsewhere:1/imageproxy/abc?size=256") == "abc")
        #expect(MANowPlayingMapper.proxyID(imageURL: "http://elsewhere:1/other/abc") == nil)
        #expect(MANowPlayingMapper.proxyID(imageURL: nil) == nil)
    }

    @Test func fallsBackToQueueCurrentItem() throws {
        guard case .object(var queueObject) = try SyntheticPlayback.queue() else { return }
        queueObject["current_item"] = [
            "queue_item_id": "qi1", "name": "Queue Name", "duration": 180,
            "image": ["type": "thumb", "proxy_id": "qproxy"],
            "media_item": [
                "uri": "library://track/9", "name": "Item Name", "artists": [["name": "Item Artist"]],
                "album": ["name": "Item Album"],
            ],
        ]
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player(title: nil, uri: nil)),
            queue: try queue(.object(queueObject)), skew: 0, now: now)
        #expect(snapshot.title == "Item Name")
        #expect(snapshot.artist == "Item Artist")
        #expect(snapshot.album == "Item Album")
        #expect(snapshot.duration == 180)
        #expect(snapshot.item == MediaID(.track, "library://track/9"))
        #expect(snapshot.artwork == ArtworkRef("qproxy"))
    }

    @Test func nullVolumeIsNil() throws {
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: try player(SyntheticPlayback.player(volume: .null)), queue: nil, skew: 0, now: now)
        #expect(snapshot.volume == nil)
    }

    @Test func idlePlayerWithNullMediaIsStopped() throws {
        let recordedPlayer = try MAFixture.playerGet.frames()[0]["result"]!.decode(as: MAPlayer.self)
        let recordedQueue = try MAFixture.playerQueueActive.frames()[0]["result"]!.decode(as: MAPlayerQueue.self)
        let snapshot = MANowPlayingMapper.snapshot(
            output: output, player: recordedPlayer, queue: recordedQueue, skew: 0, now: now)
        #expect(snapshot.state == .stopped)
        #expect(snapshot.title == nil)
        #expect(snapshot.item == nil)
        #expect(snapshot.artwork == nil)
    }
}

struct EventMatchTests {
    let id = SyntheticPlayback.playerID

    @Test func playerUpdatedWithObjectIDDecodesPlayer() throws {
        let event = MAServerEvent(event: "player_updated", objectID: id, data: try SyntheticPlayback.player(state: "paused"))
        guard case .player(let player) = MAEventMatch.classify(event, playerID: id, queueID: id) else {
            Issue.record("expected .player")
            return
        }
        #expect(player.state == .paused)
    }

    @Test func playerUpdatedWithoutObjectIDMatchesOnDataPlayerID() throws {
        let event = MAServerEvent(event: "player_updated", data: try SyntheticPlayback.player())
        guard case .player = MAEventMatch.classify(event, playerID: id, queueID: id) else {
            Issue.record("expected .player")
            return
        }
    }

    @Test func queueTimeUpdatedAcceptsBareNumber() {
        let event = MAServerEvent(event: "queue_time_updated", objectID: id, data: 42.5)
        #expect(MAEventMatch.classify(event, playerID: id, queueID: id) == .elapsed(42.5))
    }

    @Test func queueTimeUpdatedAcceptsObject() {
        let event = MAServerEvent(event: "queue_time_updated", data: ["queue_id": .string(id), "elapsed_time": 17])
        #expect(MAEventMatch.classify(event, playerID: id, queueID: id) == .elapsed(17))
    }

    @Test func otherPlayersEventsAreIgnored() throws {
        let event = MAServerEvent(event: "player_updated", objectID: "someone-else", data: try SyntheticPlayback.player())
        #expect(MAEventMatch.classify(event, playerID: id, queueID: id) == .ignore)
        let time = MAServerEvent(event: "queue_time_updated", objectID: "someone-else", data: 3)
        #expect(MAEventMatch.classify(time, playerID: id, queueID: id) == .ignore)
    }

    @Test func undecodableMatchingEventRefetches() {
        for name in ["player_updated", "queue_updated", "queue_time_updated"] {
            let event = MAServerEvent(event: name, objectID: id, data: "garbage")
            #expect(MAEventMatch.classify(event, playerID: id, queueID: id) == .refetch)
        }
        for name in ["player_added", "player_removed", "queue_added", "queue_items_updated"] {
            #expect(MAEventMatch.classify(MAServerEvent(event: name, objectID: id), playerID: id, queueID: id) == .refetch)
        }
    }

    @Test func eventWithNoIdentifiableTargetRefetches() {
        let event = MAServerEvent(event: "queue_updated", data: ["something": 1])
        #expect(MAEventMatch.classify(event, playerID: id, queueID: id) == .refetch)
    }

    @Test func unknownEventNamesAreIgnored() {
        for name in ["media_item_played", "providers_updated", "brand_new_event"] {
            #expect(MAEventMatch.classify(MAServerEvent(event: name, objectID: id), playerID: id, queueID: id) == .ignore)
        }
    }
}
