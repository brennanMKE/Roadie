import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct ClientCallTests {
    private func connected(script: FixtureScript? = nil) async throws -> ClientRig {
        let rig = try makeClient(script: script)
        _ = try await rig.connect()
        return rig
    }

    @Test func messageIDsIncrementPerCall() async throws {
        let rig = try await connected()
        _ = try await rig.client.call(.time())
        _ = try await rig.client.call(.providers())
        _ = try await rig.client.call(.playersAll())
        #expect(rig.transport.sentRequests.map(\.messageID) == ["1", "2", "3", "4"])
        await rig.client.disconnect()
    }

    @Test func repliesCorrelateByMessageIDWhenOutOfOrder() async throws {
        let rig = try await connected()
        rig.transport.replyOrder = .reversedPairs
        async let count = rig.client.call(.count(.artist, albumArtistsOnly: true))
        // Ensure the count is sent before the listing so the pair is (count, listing).
        #expect(await waitFor { rig.transport.sentRequests.count == 2 })
        async let page = rig.client.call(.libraryItems(.artist, limit: 3, offset: 0, albumArtistsOnly: true))
        let (total, items) = try await (count, page)
        #expect(total.intValue == 475)
        #expect(items.arrayValue?.count == 3)
        await rig.client.disconnect()
    }

    @Test func partialResultsAreConcatenatedUntilTheFinalFrame() async throws {
        let rig = try await connected()
        let tracks = try await rig.client.call(.playlistTracks(itemID: "4", provider: "library"), as: [MATrack].self)
        #expect(tracks.count == 5)

        var script = try FixtureScript.recorded(token: testToken)
        script.routes.insert(
            .frames(
                command: "music/playlists/playlist_tracks",
                [
                    ["result": [1, 2], "partial": true], ["result": [3, 4], "partial": true],
                    ["result": [5, 6], "partial": true], ["result": [7], "partial": false],
                ]), at: 0)
        script.routes.insert(
            .frames(command: "players/get", [["result": ["a": 1], "partial": true], ["result": nil, "partial": false]]), at: 0)
        let second = try await connected(script: script)
        let seven = try await second.client.call(.playlistTracks(itemID: "x", provider: "library"))
        #expect(seven == .array([1, 2, 3, 4, 5, 6, 7]))
        let kept = try await second.client.call(.player(id: "x"))
        #expect(kept == ["a": 1])
        await rig.client.disconnect()
        await second.client.disconnect()
    }

    @Test func aNullResultDecodesAsNil() async throws {
        let rig = try await connected()
        let missing = try await rig.client.call(.player(id: "skinamp-no-such-player"), as: MAPlayer?.self)
        #expect(missing == nil)
        do {
            _ = try await rig.client.call(.player(id: "skinamp-no-such-player"), as: MAPlayer.self)
            Issue.record("expected a decoding error")
        } catch let error as MusicAssistantError {
            guard case .decoding(let command, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(command == "players/get")
        }
        await rig.client.disconnect()
    }

    @Test func errorFramesMapToTypedErrors() async throws {
        var script = try FixtureScript.recorded(token: testToken)
        script.routes.insert(.error(command: "providers", code: 20, details: "Authentication is required."), at: 0)
        let rig = try await connected(script: script)
        await #expect(throws: MusicAssistantError.server(code: 12, details: "Invalid or unsupported command.")) {
            try await rig.client.call(MARequest(command: "skinamp/no_such_command"))
        }
        await #expect(throws: MusicAssistantError.unauthenticated) { try await rig.client.call(.providers()) }
        await rig.client.disconnect()
    }

    @Test func aCallTimesOutWhenTheServerStaysSilent() async throws {
        let rig = try await connected()
        rig.transport.unanswered = ["music/artists/count"]
        let task = Task { try await rig.client.call(.count(.artist)) }
        // The ping loop's sleeper and the call's timeout.
        #expect(await waitFor { rig.clock.sleeperCount == 2 })
        rig.clock.advance(by: .seconds(15))
        do {
            _ = try await task.value
            Issue.record("expected a timeout")
        } catch let error as MusicAssistantError {
            #expect(error == .timeout(command: "music/artists/count"))
        }
        #expect(await rig.client.pendingCallCount == 0)
        // A late reply is dropped without effect.
        rig.transport.push(#"{"message_id":"2","result":475,"partial":false}"#)
        let time = try await rig.client.call(.time())
        #expect(time.doubleValue != nil)
        await rig.client.disconnect()
    }

    @Test func aCancelledCallIsRemovedFromPending() async throws {
        let rig = try await connected()
        rig.transport.holdReplies(for: "time")
        let task = Task { try await rig.client.call(.time()) }
        #expect(await waitFor { await rig.client.pendingCallCount == 1 })
        task.cancel()
        #expect(await waitFor { await rig.client.pendingCallCount == 0 })
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        }
        rig.transport.release(command: "time")
        let again = try await rig.client.call(.providers())
        #expect(again.arrayValue?.count == 3)
        await rig.client.disconnect()
    }

    @Test func eventsGoToTheStreamNotToCallers() async throws {
        let rig = try await connected()
        let events = Collector(await rig.client.events())
        rig.transport.holdReplies(for: "time")
        let task = Task { try await rig.client.call(.time()) }
        #expect(await waitFor { await rig.client.pendingCallCount == 1 })
        rig.transport.push(#"{"event":"player_updated","object_id":"x","data":{"player_id":"x"}}"#)
        #expect(await waitFor { events.items.count == 1 })
        #expect(events.items.first?.event == "player_updated")
        #expect(events.items.first?.objectID == "x")
        events.stop()
        rig.transport.release(command: "time")
        let time = try await task.value
        #expect(time.doubleValue != nil)
        await rig.client.disconnect()
    }

    @Test func unknownFramesAreDropped() async throws {
        let rig = try await connected()
        rig.transport.push(#"{"hello":1}"#)
        rig.transport.push(#"{"message_id":"999","result":1,"partial":false}"#)
        let time = try await rig.client.call(.time())
        #expect(time.doubleValue != nil)
        await rig.client.disconnect()
    }

    @Test func decodingUsesTheTypedOverload() async throws {
        let rig = try await connected()
        let players = try await rig.client.call(.playersAll(), as: [MAPlayer].self)
        #expect(players.count == 9)
        await rig.client.disconnect()
    }
}
