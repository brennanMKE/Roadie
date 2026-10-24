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
        "players/cmd/repeat", "player_queues/play_media", "player_queues/next", "player_queues/previous", "player_queues/transfer", "players/cmd/set_members",
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

    @Test func setGroupMembersSendsSetMembers() async throws {
        let rig = try await connectedBackend(script: controlScript())
        _ = try await rig.backend.outputs()
        let kitchen = OutputDevice.ID(rawValue: "ap82fe09484ac9")
        let bedroom = OutputDevice.ID(rawValue: "ap720a998fd71d")
        try await rig.backend.setGroupMembers(of: player, adding: [kitchen], removing: [bedroom])
        let request = try #require(sent(rig, "players/cmd/set_members").first)
        #expect(request.args["target_player"] == .string(SyntheticPlayback.playerID))
        #expect(request.args["player_ids_to_add"] == ["ap82fe09484ac9"])
        #expect(request.args["player_ids_to_remove"] == ["ap720a998fd71d"])
        await rig.backend.disconnect()
    }

    @Test func setGroupMembersOmitsAnEmptyList() async throws {
        let rig = try await connectedBackend(script: controlScript())
        _ = try await rig.backend.outputs()
        try await rig.backend.setGroupMembers(
            of: player, adding: [], removing: [OutputDevice.ID(rawValue: "ap82fe09484ac9")])
        let request = try #require(sent(rig, "players/cmd/set_members").first)
        #expect(request.args["player_ids_to_add"] == nil)
        #expect(request.args["player_ids_to_remove"] == ["ap82fe09484ac9"])
        await rig.backend.disconnect()
    }

    @Test func setGroupMembersWithNothingToChangeSendsNothing() async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.setGroupMembers(of: player, adding: [], removing: [])
        #expect(sent(rig, "players/cmd/set_members").isEmpty)
        await rig.backend.disconnect()
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

    @Test func playNextSendsOptionNext() async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.play([MediaID(.album, "library://album/27")], on: player, mode: .next)
        let request = try #require(sent(rig, "player_queues/play_media").first)
        #expect(request.args["option"] == "next")
        #expect(request.args["start_item"] == nil)
        await rig.backend.disconnect()
    }

    @Test func playOnThisMacWithoutSendspinExplains() async throws {
        let rig = try await connectedBackend(script: controlScript())
        await #expect(throws: MusicBackendError.backend(MusicAssistantBackend.thisMacNotRegisteredText)) {
            try await rig.backend.play([MediaID(.album, "library://album/27")], on: OutputDevice.thisMacID, mode: .replace())
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
        (.togglePlayPause, "players/cmd/play_pause"), (.stop, "players/cmd/stop"),
    ])
    func transportCommandsMapToPlayerCommands(command: TransportCommand, expected: String) async throws {
        let rig = try await connectedBackend(script: controlScript())
        try await rig.backend.transport(command, on: player)
        let request = try #require(sent(rig, expected).first)
        #expect(request.args["player_id"] == .string(SyntheticPlayback.playerID))
        await rig.backend.disconnect()
    }

    /// #0150: next and previous go to the queue the player plays, not `players/cmd/next`.
    @Test func nextAndPreviousGoToTheActiveQueue() async throws {
        let rig = try await connectedBackend(
            script: controlScript {
                $0.override(
                    "player_queues/get_active_queue",
                    result: ["queue_id": "the_queue", "active": true, "items": 3, "current_index": 1])
            })
        try await rig.backend.transport(.next, on: player)
        try await rig.backend.transport(.previous, on: player)
        #expect(sent(rig, "player_queues/next").map { $0.args["queue_id"] } == ["the_queue"])
        #expect(sent(rig, "player_queues/previous").map { $0.args["queue_id"] } == ["the_queue"])
        #expect(sent(rig, "players/cmd/next").isEmpty)
        #expect(sent(rig, "players/cmd/previous").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func nextWithoutAnActiveQueueUsesThePlayersOwnQueue() async throws {
        let rig = try await connectedBackend(
            script: controlScript { $0.override("player_queues/get_active_queue", result: .null) })
        try await rig.backend.transport(.next, on: player)
        #expect(sent(rig, "player_queues/next").map { $0.args["queue_id"] } == [.string(SyntheticPlayback.playerID)])
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

    /// A speaker synced to another player (#0121).
    private func memberRig() async throws -> BackendRig {
        try await connectedBackend(
            script: controlScript {
                guard case .object(var object) = try SyntheticPlayback.player() else { return }
                object["synced_to"] = "leader1"
                $0.override("players/get", result: .object(object))
            })
    }

    @Test func stopOnASyncedMemberGoesToTheLeader() async throws {
        let rig = try await memberRig()
        try await rig.backend.transport(.stop, on: player)
        let request = try #require(sent(rig, "players/cmd/stop").first)
        #expect(request.args["player_id"] == "leader1")
        await rig.backend.disconnect()
    }

    @Test func volumeOnASyncedMemberStaysOnTheMember() async throws {
        let rig = try await memberRig()
        try await rig.backend.transport(.setVolume(0.5), on: player)
        let request = try #require(sent(rig, "players/cmd/volume_set").first)
        #expect(request.args["player_id"] == .string(SyntheticPlayback.playerID))
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

    // MARK: Transfer (#0117)

    /// A recorded output other than `player`.
    private func otherOutput(_ rig: BackendRig) async throws -> OutputDevice.ID {
        let outputs = try await rig.backend.outputs()
        return try #require(outputs.first { $0.id != player && $0.id != OutputDevice.thisMacID }).id
    }

    @Test func transferBetweenSpeakersSendsSourceAndTargetQueues() async throws {
        let rig = try await connectedBackend(script: controlScript {
            $0.override("player_queues/get_active_queue", result: try SyntheticPlayback.queue())
        })
        let target = try await otherOutput(rig)
        let queueID = try SyntheticPlayback.queue().decode(as: MAPlayerQueue.self).queueID
        try await rig.backend.transfer(from: player, to: target, autoPlay: true)
        let request = try #require(sent(rig, "player_queues/transfer").first)
        #expect(request.args["source_queue_id"] == .string(queueID))
        #expect(request.args["target_queue_id"] == .string(target.rawValue))
        #expect(request.args["auto_play"] == .bool(true))
        await rig.backend.disconnect()
    }

    @Test func transferUsesThePlayersOwnQueueWhenNoneIsActive() async throws {
        let rig = try await connectedBackend(script: controlScript {
            $0.override("player_queues/get_active_queue", result: .null)
        })
        let target = try await otherOutput(rig)
        try await rig.backend.transfer(from: player, to: target, autoPlay: true)
        let request = try #require(sent(rig, "player_queues/transfer").first)
        #expect(request.args["source_queue_id"] == .string(SyntheticPlayback.playerID))
        #expect(request.args["target_queue_id"] == .string(target.rawValue))
        await rig.backend.disconnect()
    }

    @Test func transferPassesAutoPlayFalseWhenPaused() async throws {
        let rig = try await connectedBackend(script: controlScript {
            $0.override("player_queues/get_active_queue", result: .null)
        })
        let target = try await otherOutput(rig)
        try await rig.backend.transfer(from: player, to: target, autoPlay: false)
        let request = try #require(sent(rig, "player_queues/transfer").first)
        #expect(request.args["auto_play"] == .bool(false))
        await rig.backend.disconnect()
    }

    @Test func transferToUnknownOutputThrowsUnknownOutput() async throws {
        let rig = try await connectedBackend(script: controlScript {
            $0.override("player_queues/get_active_queue", result: .null)
        })
        let unknown = OutputDevice.ID(rawValue: "nope")
        await #expect(throws: MusicBackendError.unknownOutput(unknown)) {
            try await rig.backend.transfer(from: player, to: unknown, autoPlay: true)
        }
        #expect(sent(rig, "player_queues/transfer").isEmpty)
        await rig.backend.disconnect()
    }

    @Test func transferToSameOutputSendsNothing() async throws {
        let rig = try await connectedBackend(script: controlScript())
        let before = rig.transport.sentRequests.count
        try await rig.backend.transfer(from: player, to: player, autoPlay: true)
        #expect(rig.transport.sentRequests.count == before)
        await rig.backend.disconnect()
    }

    @Test func transferWhenDisconnectedThrowsNotConnected() async throws {
        let rig = try makeBackend()
        let backend = rig.backend
        let player = player
        await #expect(throws: MusicBackendError.notConnected) {
            try await backend.transfer(from: player, to: OutputDevice.ID(rawValue: "other"), autoPlay: true)
        }
    }
}
