import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct MAFixtureTests {
    private static let notCalls: Set<MAFixture> = [.serverInfo, .infoHTTP, .artworkProbe, .events, .eventsPlaylists, .eventsQueue]

    @Test func everyFixtureLoadsAndParses() throws {
        #expect(MAFixture.baseline.count == 42)
        #expect(MAFixture.baseline.allSatisfy { $0.isRecorded })
        #expect(MAFixture.baseline.last == .events)
        for fixture in MAFixture.recorded {
            _ = try fixture.json
            if Self.notCalls.contains(fixture) { continue }
            #expect(fixture.command != nil, "\(fixture.rawValue) has no command")
            #expect(try !fixture.frames().isEmpty, "\(fixture.rawValue) has no frames")
        }
        #expect(try MAFixture.serverInfo.frames().count == 1)
        #expect(try MAFixture.serverInfo.frames()[0]["message_id"] == nil)
        #expect(try MAFixture.events.json["events"]?.arrayValue != nil)
        #expect(try MAFixture.infoHTTP.json["server_id"]?.stringValue == fixtureServerID)
    }

    @Test func theRecordedScriptAnswersEveryRecordedCommand() throws {
        let script = try FixtureScript.recorded(token: testToken)
        // The auth fixtures carry a placeholder token, and two others share a command with a fixture that wins the route.
        let skipped: Set<MAFixture> = [
            .authOk, .errorAuth, .errorUnauthenticated, .playersAllUnavailable,
            .playersAllSendspin, .playersAllSendspinUnavailable,
        ]
        var checked = 0
        for fixture in MAFixture.baseline where !Self.notCalls.contains(fixture) && !skipped.contains(fixture) {
            let command = try #require(fixture.command)
            let args = try #require(fixture.args)
            let replies = script.replies(command: command, args: args, messageID: "99")
            let recorded = try fixture.frames()
            #expect(replies.count == recorded.count, "\(fixture.rawValue): frame count")
            for (reply, frame) in zip(replies, recorded) {
                let parsed = try MAJSON.parse(reply)
                #expect(parsed["message_id"] == "99", "\(fixture.rawValue): message id")
                #expect(parsed["result"] == frame["result"], "\(fixture.rawValue): result")
                #expect(parsed["error_code"] == frame["error_code"], "\(fixture.rawValue): error code")
            }
            checked += 1
        }
        #expect(checked == 32)
    }

    @Test func pendingCapturesAreSkippedUntilRecorded() throws {
        // #0133: the playlist captures are optional until the user records them; each one present must parse.
        for fixture in MAFixture.allCases where !MAFixture.baseline.contains(fixture) && fixture.isRecorded {
            _ = try fixture.json
        }
        #expect(throws: MAFixture.Missing.self) { try MAFixture.recommendationItems(row: "roadie-no-such-row") }
    }

    /// The server quirks in `docs/ma-protocol-notes.md` "Quirks", each checked against the fixture that shows it; a
    /// quirk whose fixture is not recorded yet is skipped. When this fails, a re-record changed the server's behaviour:
    /// update the quirk entry (and reconsider the code that relies on it, such as `MAQueueWatch.item(_:position:)`
    /// for (a)); don't edit the fixture.
    @Test func recordedQuirksHold() throws {
        // (a) `player_queues/items` rows carry `"index": 0` whatever their position (MA 2.10.6, #0187).
        if MAFixture.playerQueueItemsLoaded.isRecorded {
            let rows = try MAFixture.playerQueueItemsLoaded.frames().flatMap { $0["result"]?.arrayValue ?? [] }
            #expect(rows.count > 1, "the loaded queue recording needs more than one row to show the quirk")
            #expect(rows.allSatisfy { $0["index"]?.intValue == 0 }, "rows no longer all carry index 0")
        }
        if MAFixture.playerQueueGetLoaded.isRecorded {
            let queue = try recordedResult(.playerQueueGetLoaded)
            #expect(queue["current_index"]?.intValue != nil, "the loaded queue has no current_index")
        }
        // (b) `playlist_tracks` streams chunk frames, then an empty `partial: false`.
        let chunks = try MAFixture.playlistTracks.frames()
        #expect(chunks.count >= 2)
        #expect(chunks.dropLast().allSatisfy { $0["partial"]?.boolValue == true })
        #expect(chunks.last?["partial"]?.boolValue == false)
        #expect(chunks.last?["result"]?.arrayValue?.isEmpty == true)
        // (c) `players/get` of an unknown id answers `result: null`, not an error.
        let unknown = try MAFixture.errorUnknownPlayer.frames()
        #expect(unknown.count == 1)
        #expect(unknown.first?["result"] == .null)
        #expect(unknown.first?["error_code"] == nil)
        // (d) Builtin playlists all carry owner "Music Assistant" (#0221). Skipped while `playlists-page.json` still has
        // the owners scrubbed to "user" by the recorder before #0221.
        let playlists = try recordedResult(.playlistsPage).arrayValue ?? []
        if !playlists.contains(where: { $0["owner"]?.stringValue == "user" }) {
            #expect(playlists.allSatisfy { $0["owner"]?.stringValue == "Music Assistant" })
        }
    }

    /// Fixtures are verbatim recordings: each call has `command`, `args` and `frames`, nothing is marked synthetic,
    /// and the folder holds exactly `MAFixture.recorded` (plus the derived `commands-names` and the per-row
    /// `recommendations-items-*`).
    @Test func fixturesAreVerbatimRecordings() throws {
        func hasSyntheticKey(_ value: MAJSON) -> Bool {
            switch value {
            case .object(let object): object.keys.contains("synthetic") || object.values.contains(where: hasSyntheticKey)
            case .array(let array): array.contains(where: hasSyntheticKey)
            default: false
            }
        }
        for fixture in MAFixture.recorded {
            let json = try fixture.json
            if !Self.notCalls.contains(fixture) {
                #expect(json["command"]?.stringValue != nil, "\(fixture.rawValue): command")
                #expect(json["args"]?.objectValue != nil, "\(fixture.rawValue): args")
                #expect(json["frames"]?.arrayValue != nil, "\(fixture.rawValue): frames")
            }
            #expect(!hasSyntheticKey(json), "\(fixture.rawValue): synthetic key")
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/MusicAssistantKitStub/Fixtures").standardizedFileURL
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter { $0 != "commands-names" && !$0.hasPrefix("recommendations-items-") }
        #expect(Set(names) == Set(MAFixture.recorded.map(\.rawValue)))
    }

    /// The loaded-queue routes (#0196) over a SYNTHETIC stand-in page of 5 rows recorded at `limit: 50` on the
    /// baseline's queue id: a shorter `limit` gets that many rows, the recorded `limit` gets the page as recorded, a
    /// larger `limit` or another offset falls through, and the baseline's own args still get the baseline's `[]`.
    @Test func loadedQueueRoutesSliceToTheAskedLimitAndSpareTheBaseline() throws {
        let baselineArgs = try #require(MAFixture.playerQueueItems.args)
        let queue = try #require(baselineArgs["queue_id"])
        let rows: [MAJSON] = (0..<5).map { ["queue_item_id": .string("qi\($0)"), "index": 0] }
        let page: MAJSON = ["queue_id": queue, "limit": 50, "offset": 0]
        let script = FixtureScript(
            routes: FixtureScript.loadedQueueRoutes(
                pages: [(args: page, frames: [["result": .array(rows), "partial": false]])],
                baseline: (args: baselineArgs, frames: try MAFixture.playerQueueItems.frames())),
            fallbackFrames: [["result": "fallthrough"]])
        func ask(limit: Int, offset: Int = 0) throws -> MAJSON? {
            let replies = script.replies(
                command: "player_queues/items",
                args: ["queue_id": queue, "limit": .number(Double(limit)), "offset": .number(Double(offset))],
                messageID: "7")
            #expect(replies.count == 1)
            return try MAJSON.parse(replies[0])["result"]
        }
        #expect(try ask(limit: 2)?.arrayValue == Array(rows.prefix(2)))
        #expect(try ask(limit: 50)?.arrayValue == rows)
        #expect(try ask(limit: 51) == "fallthrough")
        #expect(try ask(limit: 2, offset: 50) == "fallthrough")
        #expect(baselineArgs["limit"]?.intValue == 3 && baselineArgs["offset"]?.intValue == 0)
        #expect(try ask(limit: 3)?.arrayValue == [])
    }

    @Test func authAnswersByToken() throws {
        let script = try FixtureScript.recorded(token: testToken)
        let good = script.replies(command: "auth", args: ["token": "ma-UNIT-TEST-TOKEN"], messageID: "1")
        let bad = script.replies(command: "auth", args: ["token": "something-else"], messageID: "1")
        #expect(try MAJSON.parse(good[0])["result"]?["authenticated"] == true)
        #expect(try MAJSON.parse(bad[0])["error_code"]?.intValue == 23)
    }

    @Test func jsonRoundTripsWholeNumbersAndEscapes() throws {
        let value: MAJSON = ["a": 12, "b": 1.5, "c": "q\"\\\n", "d": [true, nil], "e": ["x": 0]]
        let text = value.encodedString()
        #expect(text == "{\"a\":12,\"b\":1.5,\"c\":\"q\\\"\\\\\\n\",\"d\":[true,null],\"e\":{\"x\":0}}")
        #expect(try MAJSON.parse(text) == value)
        #expect(try MAJSON.parse("1") == .number(1))
        #expect(try MAJSON.parse("true") == .bool(true))
    }
}
