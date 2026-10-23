import Foundation
import Testing
@testable import SendspinKit

struct SendspinMessagesTests {
    /// Roadie's own Sendspin identity (#0155). The hello test reads the recorded probe's identity, so this pins ours.
    @Test func identityAndDeviceInfoNameRoadie() throws {
        let device = SendspinDeviceInfo(softwareVersion: "1")
        #expect(device.productName == "Roadie")
        #expect(device.manufacturer == "Roadie")
        let suite = "SendspinMessagesTests.identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let minted = SendspinIdentity.load(defaults: defaults, hostName: "Test Mac")
        #expect(minted.name == "Roadie (Test Mac)")
        #expect(minted.clientID.hasPrefix("roadie-"))
        #expect(SendspinIdentity.load(defaults: defaults, hostName: "Other").clientID == minted.clientID)
    }

    @Test func clientHelloEncodesTheLegacyShape() throws {
        let recorded = try #require(try fixtureFrames().first { $0.dir == "out" && $0.frame["type"] as? String == "client/hello" })
        // The identity is whatever the probe sent when the fixture was recorded, so it comes from the fixture.
        let sent = try #require(recorded.frame["payload"] as? [String: Any])
        let device = try #require(sent["device_info"] as? [String: Any])
        let hello = SendspinClientHello(
            clientID: try #require(sent["client_id"] as? String), name: try #require(sent["name"] as? String),
            deviceInfo: SendspinDeviceInfo(
                productName: try #require(device["product_name"] as? String),
                manufacturer: try #require(device["manufacturer"] as? String), softwareVersion: "probe"),
            playerSupport: SendspinPlayerSupport(supportedFormats: [SendspinAudioFormat(sampleRate: 48_000)], bufferCapacity: 1_048_576))
        let encoded = jsonObject(SendspinOutgoing.encode(hello))
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
