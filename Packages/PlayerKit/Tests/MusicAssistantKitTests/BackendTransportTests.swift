import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// The recorded script plus a null result for every command a player is sent (none was recorded: #0060 never
/// changed playback).
func controlScript(_ change: (inout FixtureScript) throws -> Void = { _ in }) throws -> FixtureScript {
    var script = try FixtureScript.recorded(token: testToken)
    for command in [
        "players/cmd/play", "players/cmd/pause", "players/cmd/play_pause", "players/cmd/stop", "players/cmd/next",
        "players/cmd/previous", "players/cmd/seek", "players/cmd/volume_set", "players/cmd/shuffle",
        "players/cmd/repeat", "player_queues/play_media",
    ] {
        script.override(command, result: .null)
    }
    try change(&script)
    return script
}

struct BackendTransportTests {
    let player = OutputDevice.ID(rawValue: SyntheticPlayback.playerID)

    private func sent(_ rig: BackendRig, _ command: String) -> [SentRequest] {
        rig.transport.sentRequests.filter { $0.command == command }
    }

    @Test func playAlbumSendsPlayMediaReplace() async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.play([MediaID(.album, "library://album/27")], on: player, mode: .replace())
        let request = try #require(sent(rig, "player_queues/play_media").first)
        #expect(request.args["queue_id"] == .string(SyntheticPlayback.playerID))
        #expect(request.args["media"] == ["library://album/27"])
        #expect(request.args["option"] == "replace")
        #expect(request.args["start_item"] == nil)
        await rig.backend.disconnect()
    }

    @Test func playTracksFromIndexSendsStartItem() async throws {
        let rig = try await connectedBackend(script: controlScript())
        let tracks = (1...4).map { MediaID(.track, "library://track/\($0)") }
        try await rig.backend.play(tracks, on: player, mode: .replace(startIndex: 2))
        let request = try #require(sent(rig, "player_queues/play_media").first)
        #expect(request.args["media"]?.arrayValue?.count == 4)
        #expect(request.args["option"] == "replace")
        #expect(request.args["start_item"] == "library://track/3")
        await rig.backend.disconnect()
    }

    @Test func appendSendsOptionAdd() async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.play([MediaID(.playlist, "library://playlist/2")], on: player, mode: .append)
        let request = try #require(sent(rig, "player_queues/play_media").first)
        #expect(request.args["option"] == "add")
        #expect(request.args["start_item"] == nil)
        await rig.backend.disconnect()
    }

    @Test func playOnThisMacExplainsHowToPickASpeaker() async throws {
        let rig = try await connectedBackend(script: controlScript())
        do {
            try await rig.backend.play([MediaID(.album, "library://album/27")], on: OutputDevice.thisMacID, mode: .replace())
            Issue.record("expected an error")
        } catch let error as MusicBackendError {
            guard case .backend(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("Output menu"))
        }
        #expect(sent(rig, "player_queues/play_media").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func playOnUnknownPlayerThrowsUnknownOutput() async throws {
        let rig = try await connectedBackend(script: controlScript())
        let unknown = OutputDevice.ID(rawValue: "nope")
        await #expect(throws: MusicBackendError.unknownOutput(unknown)) {
            try await rig.backend.play([MediaID(.album, "library://album/27")], on: unknown, mode: .replace())
        }
        #expect(sent(rig, "players/get").count == 1)
        #expect(sent(rig, "player_queues/play_media").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func emptyPlayRequestSendsNothing() async throws {
        let rig = try await connectedBackend(script: controlScript())
        let before = rig.transport.sentRequests.count
        try await rig.backend.play([], on: player, mode: .append)
        #expect(rig.transport.sentRequests.count == before)
        await rig.backend.disconnect()
    }

    @Test(arguments: [
        (TransportCommand.play, "players/cmd/play"), (.pause, "players/cmd/pause"),
        (.togglePlayPause, "players/cmd/play_pause"), (.stop, "players/cmd/stop"), (.next, "players/cmd/next"),
        (.previous, "players/cmd/previous"),
    ])
    func transportCommandsMapToPlayerCommands(command: TransportCommand, expected: String) async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.transport(command, on: player)
        let request = try #require(sent(rig, expected).first)
        #expect(request.args["player_id"] == .string(SyntheticPlayback.playerID))
        await rig.backend.disconnect()
    }

    @Test func seekSendsRoundedIntegerSeconds() async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.transport(.seek(61.6), on: player)
        try await rig.backend.transport(.seek(-3), on: player)
        #expect(sent(rig, "players/cmd/seek").map { $0.args["position"] } == [62, 0])
        #expect(rig.transport.sent.contains { $0.contains("\"position\":62") })
        await rig.backend.disconnect()
    }

    @Test func volumeScalesToPercentAndClamps() async throws {
        let rig = try await connectedBackend(script: controlScript())
        for volume: Float in [0.574, 1.4, -0.2] { try await rig.backend.transport(.setVolume(volume), on: player) }
        #expect(sent(rig, "players/cmd/volume_set").map { $0.args["volume_level"] } == [57, 100, 0])
        await rig.backend.disconnect()
    }

    @Test func volumeOnPlayerWithoutVolumeControlIsUnsupported() async throws {
        let nullVolume = try await connectedBackend(
            script: controlScript { $0.override("players/get", result: try SyntheticPlayback.player(volume: .null)) })
        await #expect(throws: MusicBackendError.unsupported(.remoteOutputs)) {
            try await nullVolume.backend.transport(.setVolume(0.5), on: player)
        }
        #expect(sent(nullVolume, "players/cmd/volume_set").isEmpty)
        await nullVolume.backend.disconnect()

        let noFeature = try await connectedBackend(
            script: controlScript {
                $0.override("players/get", result: try SyntheticPlayback.player(supportedFeatures: ["play_media", "pause"]))
            })
        await #expect(throws: MusicBackendError.unsupported(.remoteOutputs)) {
            try await noFeature.backend.transport(.setVolume(0.5), on: player)
        }
        #expect(sent(noFeature, "players/cmd/volume_set").isEmpty)
        await noFeature.backend.disconnect()
    }

    @Test func shuffleAndRepeatMap() async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.transport(.setShuffle(true), on: player)
        try await rig.backend.transport(.setRepeat(true), on: player)
        try await rig.backend.transport(.setRepeat(false), on: player)
        #expect(sent(rig, "players/cmd/shuffle").map { $0.args["shuffle_enabled"] } == [true])
        #expect(sent(rig, "players/cmd/repeat").map { $0.args["repeat_mode"] } == ["all", "off"])
        await rig.backend.disconnect()
    }

    @Test func balanceIsUnsupportedAndSendsNothing() async throws {
        let rig = try await connectedBackend(script: controlScript())
        _ = try await rig.backend.outputs()
        let before = rig.transport.sentRequests.count
        await #expect(throws: MusicBackendError.unsupported(.remoteOutputs)) {
            try await rig.backend.transport(.setBalance(0.5), on: player)
        }
        #expect(rig.transport.sentRequests.count == before)
        await rig.backend.disconnect()
    }

    @Test func commandsUseThePlayerCacheNotPlayersAll() async throws {
        let rig = try await connectedBackend(script: controlScript())
        for step in 0..<20 { try await rig.backend.transport(.setVolume(Float(step) / 20), on: player) }
        try await rig.backend.transport(.play, on: player)
        #expect(sent(rig, "players/all").count <= 1)
        #expect(sent(rig, "players/get").count == 1)
        #expect(sent(rig, "players/cmd/volume_set").count == 20)
        await rig.backend.disconnect()
    }

    @Test func serverErrorOnCommandMapsToBackendError() async throws {
        let rig = try await connectedBackend(
            script: controlScript {
                $0.routes.insert(.error(command: "players/cmd/play", code: 999, details: "Player is off"), at: 0)
            })
        do {
            try await rig.backend.transport(.play, on: player)
            Issue.record("expected an error")
        } catch let error as MusicBackendError {
            guard case .backend = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        await rig.backend.disconnect()
    }
}
