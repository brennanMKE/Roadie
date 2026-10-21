import Foundation
import MusicAssistantKitStub
import Testing
@testable import MusicAssistantKit

struct MAFixtureTests {
    private static let notCalls: Set<MAFixture> = [.serverInfo, .infoHTTP, .artworkProbe, .events, .eventsPlaylists]

    @Test func everyFixtureLoadsAndParses() throws {
        #expect(MAFixture.baseline.count == 42)
        #expect(MAFixture.baseline.allSatisfy(\.isRecorded))
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
        #expect(throws: MAFixture.Missing.self) { try MAFixture.recommendationItems(row: "skinamp-no-such-row") }
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
