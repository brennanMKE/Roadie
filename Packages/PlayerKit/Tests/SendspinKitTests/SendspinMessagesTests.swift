import Foundation
import Testing
@testable import SendspinKit

struct SendspinMessagesTests {
    @Test func clientHelloEncodesTheLegacyShape() throws {
        let hello = SendspinClientHello(
            clientID: "skinamp-probe", name: "SkinAmp probe", deviceInfo: SendspinDeviceInfo(softwareVersion: "probe"),
            playerSupport: SendspinPlayerSupport(supportedFormats: [SendspinAudioFormat(sampleRate: 48_000)], bufferCapacity: 1_048_576))
        let encoded = jsonObject(SendspinOutgoing.encode(hello))
        let recorded = try #require(try fixtureFrames().first { $0.dir == "out" && $0.frame["type"] as? String == "client/hello" })
        #expect(NSDictionary(dictionary: encoded).isEqual(to: recorded.frame))
        let payload = try #require(encoded["payload"] as? [String: Any])
        #expect(payload["version"] as? Int == 1)
        let support = try #require(payload["player@v1_support"] as? [String: Any])
        #expect(support["supported_commands"] as? [String] == ["volume", "mute"])
    }

    @Test func serverHelloDecodesTheProbedFrame() throws {
        guard case .serverHello(let hello) = try SendspinIncoming.decode(try fixtureText(type: "server/hello")) else {
            Issue.record("not a server/hello")
            return
        }
        #expect(hello.activeRoles == ["player@v1"])
        #expect(hello.connectionReason == "discovery")
        #expect(hello.version == 1)
    }

    @Test func groupUpdateWithoutGroupNameDecodes() throws {
        guard case .groupUpdate(let update) = try SendspinIncoming.decode(try fixtureText(type: "group/update")) else {
            Issue.record("not a group/update")
            return
        }
        #expect(update.playbackState == "stopped")
        #expect(update.groupID != nil)
        #expect(update.groupName == nil)
    }

    @Test func unknownTypesAndFieldsAreIgnored() throws {
        #expect(try SendspinIncoming.decode(#"{"type":"server/state","payload":{"metadata":{"title":"x"}}}"#) == .ignored(type: "server/state"))
        let extra = #"{"type":"group/update","payload":{"playback_state":"playing","future_field":7},"extra":true}"#
        guard case .groupUpdate(let update) = try SendspinIncoming.decode(extra) else {
            Issue.record("not a group/update")
            return
        }
        #expect(update.playbackState == "playing")
        #expect(throws: SendspinError.malformed(type: "server/time")) {
            try SendspinIncoming.decode(#"{"type":"server/time","payload":{"client_transmitted":"x"}}"#)
        }
    }

    @Test func serverCommandVolumeAndMuteDecode() throws {
        guard case .serverCommand(let volume) = try SendspinIncoming.decode(try fixtureText(type: "server/command", index: 0)),
              case .serverCommand(let mute) = try SendspinIncoming.decode(try fixtureText(type: "server/command", index: 1))
        else {
            Issue.record("not server/command")
            return
        }
        #expect(volume.player?.command == .volume)
        #expect(volume.player?.volume == 42)
        #expect(mute.player?.command == .mute)
        #expect(mute.player?.mute == true)
        let other = try SendspinIncoming.decode(#"{"type":"server/command","payload":{"player":{"command":"dance"}}}"#)
        #expect(other == .serverCommand(SendspinServerCommand(player: SendspinPlayerCommand(command: .other("dance")))))
    }

    @Test func clientStateCarriesAvailableAndTheFullPlayerObject() throws {
        let state = SendspinClientState(available: true, player: SendspinPlayerState(volume: 50, muted: false, requiredLeadTimeMs: 500, minBufferMs: 200))
        let text = SendspinOutgoing.encode(state)
        let encoded = jsonObject(text)
        #expect(encoded["type"] as? String == "client/state")
        let payload = try #require(encoded["payload"] as? [String: Any])
        #expect(payload["available"] as? Bool == true)
        let player = try #require(payload["player"] as? [String: Any])
        #expect(Set(player.keys) == ["volume", "muted", "static_delay_ms", "required_lead_time_ms", "min_buffer_ms", "supported_commands"])
        #expect(!text.contains("output_delay_ms"))
        let recorded = try #require(try fixtureFrames().first { $0.frame["type"] as? String == "client/state" })
        #expect(NSDictionary(dictionary: encoded).isEqual(to: recorded.frame))
    }
}
