import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// This Mac as a Music Assistant player: the universal player wrapping SkinAmp's Sendspin client (#0107).
struct MusicAssistantThisMacTests {
    static let clientID = "skinamp-test"
    static let wrapperID = "upf00dfeed"
    let album = MediaID(.album, "library://album/27")

    private func rig(
        players fixture: MAFixture = .playersAllSendspin, clientID: String? = clientID,
        _ change: (inout FixtureScript) throws -> Void = { _ in }
    ) async throws -> BackendRig {
        let rig = try await connectedBackend(
            script: controlScript {
                $0.override("players/all", result: try recordedResult(fixture))
                try change(&$0)
            })
        await rig.backend.setLocalSendspinClientID(clientID)
        return rig
    }

    private func sent(_ rig: BackendRig, _ command: String) -> [SentRequest] {
        rig.transport.sentRequests.filter { $0.command == command }
    }

    private func allPlayers(_ fixture: MAFixture) throws -> [MAPlayer] {
        try recordedResult(fixture).decode(as: [MAPlayer].self)
    }

    @Test func playerHostsItsSendspinClientThroughOutputProtocols() throws {
        let players = try allPlayers(.playersAllSendspin)
        let wrapper = try #require(players.first { $0.playerID == Self.wrapperID })
        #expect(wrapper.hosts(sendspinClientID: Self.clientID))
        let standalone = try #require(players.first { $0.provider == "sendspin" })
        #expect(standalone.hosts(sendspinClientID: standalone.playerID))
        let airplay = try #require(players.first { $0.playerID == "ap223aed81fe30" })
        #expect(airplay.outputProtocols?.contains { $0.protocolDomain == "sendspin" } == true)
        #expect(!airplay.hosts(sendspinClientID: Self.clientID))
    }

    @Test func outputsHideSkinAmpsOwnPlayer() async throws {
        let withID = try await rig()
        #expect(try await withID.backend.outputs().allSatisfy { $0.id.rawValue != Self.wrapperID })
        await withID.backend.disconnect()
        let without = try await rig(clientID: nil)
        #expect(try await without.backend.outputs().contains { $0.id.rawValue == Self.wrapperID })
        await without.backend.disconnect()
    }

    @Test func outputsCarryGroupableWithAndMapThisMac() async throws {
        let rig = try await rig {
            $0.override(
                "players/all",
                result: [
                    ["player_id": .string(Self.wrapperID), "type": "player", "name": "SkinAmp", "available": true,
                     "output_protocols": [["output_protocol_id": .string(Self.clientID), "protocol_domain": "sendspin"]]],
                    ["player_id": "kitchen", "type": "player", "name": "Kitchen", "available": true,
                     "can_group_with": [.string(Self.wrapperID), "bedroom"]],
                    ["player_id": "bedroom", "type": "player", "name": "Bedroom", "available": true],
                ])
        }
        let outputs = try await rig.backend.outputs()
        let kitchen = try #require(outputs.first { $0.id.rawValue == "kitchen" })
        #expect(kitchen.groupableWith == [OutputDevice.thisMacID, OutputDevice.ID(rawValue: "bedroom")])
        #expect(outputs.first { $0.id.rawValue == "bedroom" }?.groupableWith == nil)
        await rig.backend.disconnect()
    }

    @Test func setGroupMembersMapsThisMacToItsPlayerID() async throws {
        let rig = try await rig { $0.override("players/cmd/set_members", result: .null) }
        let speaker = OutputDevice.ID(rawValue: "ap82fe09484ac9")
        _ = try await rig.backend.outputs()
        try await rig.backend.setGroupMembers(of: OutputDevice.thisMacID, adding: [speaker], removing: [])
        _ = try await rig.backend.outputs()
        try await rig.backend.setGroupMembers(of: speaker, adding: [OutputDevice.thisMacID], removing: [])
        let requests = sent(rig, "players/cmd/set_members")
        #expect(requests.count == 2)
        #expect(requests.first?.args["target_player"] == .string(Self.wrapperID))
        #expect(requests.first?.args["player_ids_to_add"] == ["ap82fe09484ac9"])
        #expect(requests.last?.args["target_player"] == "ap82fe09484ac9")
        #expect(requests.last?.args["player_ids_to_add"] == .array([.string(Self.wrapperID)]))
        await rig.backend.disconnect()
    }

    @Test func setGroupMembersOnThisMacWithoutSendspinExplains() async throws {
        let rig = try await rig(clientID: nil) { $0.override("players/cmd/set_members", result: .null) }
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.thisMacNotRegisteredText)) {
            try await rig.backend.setGroupMembers(
                of: OutputDevice.thisMacID, adding: [OutputDevice.ID(rawValue: "ap82fe09484ac9")], removing: [])
        }
        #expect(sent(rig, "players/cmd/set_members").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func playOnThisMacTargetsTheWrappingPlayer() async throws {
        let rig = try await rig()
        let tracks = (1...3).map { MediaID(.track, "library://track/\($0)") }
        try await rig.backend.play(tracks, on: OutputDevice.thisMacID, mode: .replace(startIndex: 1))
        let request = try #require(sent(rig, "player_queues/play_media").first)
        #expect(request.args["queue_id"] == .string(Self.wrapperID))
        #expect(request.args["option"] == "replace")
        #expect(request.args["start_item"] == "library://track/2")
        await rig.backend.disconnect()
    }

    @Test func transferFromThisMacUsesTheWrappingPlayersQueue() async throws {
        let rig = try await rig { $0.override("player_queues/get_active_queue", result: .null) }
        let speaker = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)
        try await rig.backend.transfer(from: OutputDevice.thisMacID, to: speaker, autoPlay: true)
        let request = try #require(sent(rig, "player_queues/transfer").first)
        #expect(request.args["source_queue_id"] == .string(Self.wrapperID))
        #expect(request.args["target_queue_id"] == .string(SyntheticPlayback.playerID))
        await rig.backend.disconnect()
    }

    @Test func transferToThisMacTargetsTheWrappingPlayer() async throws {
        let rig = try await rig { $0.override("player_queues/get_active_queue", result: .null) }
        let speaker = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)
        try await rig.backend.transfer(from: speaker, to: OutputDevice.thisMacID, autoPlay: true)
        let request = try #require(sent(rig, "player_queues/transfer").first)
        #expect(request.args["source_queue_id"] == .string(SyntheticPlayback.playerID))
        #expect(request.args["target_queue_id"] == .string(Self.wrapperID))
        await rig.backend.disconnect()
    }

    @Test func transferToThisMacWithoutClientIDExplains() async throws {
        let rig = try await rig(clientID: nil) { $0.override("player_queues/get_active_queue", result: .null) }
        let speaker = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.thisMacNotRegisteredText)) {
            try await rig.backend.transfer(from: speaker, to: OutputDevice.thisMacID, autoPlay: true)
        }
        #expect(sent(rig, "player_queues/transfer").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func playOnThisMacWithoutClientIDExplains() async throws {
        let rig = try await rig(clientID: nil)
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.thisMacNotRegisteredText)) {
            try await rig.backend.play([album], on: OutputDevice.thisMacID, mode: .replace())
        }
        #expect(sent(rig, "player_queues/play_media").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func playOnThisMacBeforeTheWrapperExistsSaysPending() async throws {
        let rig = try await rig(players: .playersAll)
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.thisMacPendingText)) {
            try await rig.backend.play([album], on: OutputDevice.thisMacID, mode: .replace())
        }
        #expect(sent(rig, "player_queues/play_media").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func playOnThisMacWhenUnavailableSaysSo() async throws {
        let rig = try await rig(players: .playersAllSendspinUnavailable)
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.thisMacUnavailableText)) {
            try await rig.backend.play([album], on: OutputDevice.thisMacID, mode: .replace())
        }
        #expect(sent(rig, "player_queues/play_media").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func transportOnThisMacMapsToThePlayerID() async throws {
        let rig = try await rig()
        try await rig.backend.transport(.stop, on: OutputDevice.thisMacID)
        let stop = try #require(sent(rig, "players/cmd/stop").first)
        #expect(stop.args["player_id"] == .string(Self.wrapperID))
        try await rig.backend.transport(.seek(42), on: OutputDevice.thisMacID)
        let seek = try #require(sent(rig, "players/cmd/seek").first)
        #expect(seek.args["player_id"] == .string(Self.wrapperID))
        #expect(seek.args["position"] == 42)
        await rig.backend.disconnect()
    }

    @Test func volumeAndBalanceOnThisMacAreLocal() async throws {
        let rig = try await rig()
        await #expect(throws: MusicBackendError.unsupported(.localOutput)) {
            try await rig.backend.transport(.setVolume(0.5), on: OutputDevice.thisMacID)
        }
        await #expect(throws: MusicBackendError.unsupported(.localOutput)) {
            try await rig.backend.transport(.setBalance(0.2), on: OutputDevice.thisMacID)
        }
        #expect(sent(rig, "players/cmd/volume_set").isEmpty)
        #expect(!rig.transport.sentRequests.contains { $0.command == "players/all" })
        await rig.backend.disconnect()
    }

    @Test func nowPlayingOnThisMacFollowsTheWrapperAndReportsThisMac() async throws {
        let rig = try await rig {
            $0.override("players/get", result: try SyntheticPlayback.player())
            $0.override("player_queues/get_active_queue", result: try SyntheticPlayback.queue())
        }
        let collector = Collector(await rig.backend.nowPlaying(on: OutputDevice.thisMacID))
        #expect(await waitFor { collector.items.contains { $0.state == .playing } })
        #expect(collector.items.allSatisfy { $0.output == OutputDevice.thisMacID })
        let playing = try #require(collector.items.last)
        #expect(playing.title == "Synthetic Song")
        let get = try #require(sent(rig, "players/get").first)
        #expect(get.args["player_id"] == .string(Self.wrapperID))
        collector.stop()
        await rig.backend.disconnect()
    }

    @Test func capabilitiesIncludeLocalOutput() throws {
        let rig = try makeBackend()
        #expect(rig.backend.capabilities.contains(.localOutput))
        #expect(rig.backend.capabilities.contains(.remoteOutputs))
    }

    @Test func sendspinEndpointFollowsTheConnection() async throws {
        let rig = try makeBackend()
        #expect(await rig.backend.sendspinEndpoint() == nil)
        try await rig.backend.connect()
        let endpoint = try #require(await rig.backend.sendspinEndpoint())
        #expect(endpoint.baseURL == testBaseURL)
        #expect(endpoint.token == testToken)
        #expect(!endpoint.description.contains(testToken.rawValue))
        await rig.backend.disconnect()
        #expect(await rig.backend.sendspinEndpoint() == nil)
    }
}
