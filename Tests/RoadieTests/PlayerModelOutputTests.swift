import Foundation
import LibraryBrowser
import MusicAssistantKit
import MusicAssistantKitStub
import MusicBackendKit
import XCTest

@testable import Roadie

/// Output selection, groups and the This Mac feed through `PlayerModel` (#0211).
@MainActor
final class PlayerModelOutputTests: PlayerModelTestCase {
    /// The hidden native Sendspin player in `players-all.json`: its player id is its Sendspin client id, so it stands
    /// in for Roadie's own Sendspin client (the scripted configuration turns Sendspin off; it would open a socket).
    static let sendspinClientID = "AslV4UN6Oi7XVxjaNeZpTTX9YfRobkVWH0d5YPAo23U"

    /// `OutputMove` through the model. This Mac (stopped) → the playing speaker only selects it. Back to This Mac
    /// while it plays: without a Sendspin session there is no Music Assistant player for This Mac, so nothing is
    /// transferred, the notice says so and the feed falls back to local. With the Sendspin client registered (what
    /// `SendspinController.begin` does), the same move transfers the speaker's queue to that player and Music
    /// Assistant feeds This Mac.
    func testSelectOutputMovesPlayback() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        let speaker = try await selectSpeakerWithQueue(model)
        XCTAssertEqual(model.selectedOutput, speaker)
        XCTAssertFalse(commands(server).contains("player_queues/transfer"), "selecting a playing speaker moves nothing")
        try await waitUntil("the speaker plays") { model.nowPlaying.output == speaker && model.nowPlaying.state == .playing }

        // No Sendspin session: the move is refused with the Settings hint.
        model.clearNotice()
        model.selectOutput(OutputDevice.thisMacID)
        XCTAssertEqual(model.selectedOutput, OutputDevice.thisMacID)
        XCTAssertEqual(model.thisMacFeed, .musicAssistant, "the windows follow Music Assistant while the move runs")
        try await waitUntil("the refusal") { model.notice?.text == MusicAssistantBackend.thisMacNotRegisteredText }
        XCTAssertEqual(model.thisMacFeed, .local)
        XCTAssertFalse(commands(server).contains("player_queues/transfer"))

        // Back to the speaker (This Mac is stopped: a plain select), then register This Mac's Sendspin client.
        model.selectOutput(speaker)
        try await waitUntil("the speaker plays again") {
            model.nowPlaying.output == speaker && model.nowPlaying.state == .playing
        }
        XCTAssertFalse(commands(server).contains("player_queues/transfer"))
        await model.musicAssistant.setLocalSendspinClientID(Self.sendspinClientID)

        model.clearNotice()
        model.selectOutput(OutputDevice.thisMacID)
        XCTAssertEqual(model.thisMacFeed, .musicAssistant)
        XCTAssertFalse(model.playsLocalQueue)
        try await waitUntil("transfer") { self.commands(server).contains("player_queues/transfer") }
        let sent = try XCTUnwrap(server.receivedCommands.last { $0.command == "player_queues/transfer" })
        XCTAssertEqual(sent.args["source_queue_id"]?.stringValue, ScriptedMusicAssistant.speakerID)
        XCTAssertEqual(sent.args["target_queue_id"]?.stringValue, Self.sendspinClientID)
        XCTAssertEqual(sent.args["auto_play"]?.boolValue, true, "a playing queue keeps playing")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.notice, "\(String(describing: model.notice))")
        XCTAssertEqual(model.thisMacFeed, .musicAssistant)
    }

    func testToggleOutputBuildsGroups() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        let speaker = try await selectSpeakerWithQueue(model)
        let others = model.outputPicker.devices.filter { $0.kind == .remote && $0.id != speaker && !$0.isGroup }
        // players-all.json has several available speakers (Living Room, Kitchen, Living Room Display).
        let other = try XCTUnwrap(others.first, "no second speaker in the recording: \(model.outputPicker.devices)")
        model.toggleOutput(other.id)
        try await waitUntil("set_members") { self.commands(server).contains("players/cmd/set_members") }
        let sent = try XCTUnwrap(server.receivedCommands.last { $0.command == "players/cmd/set_members" })
        XCTAssertEqual(sent.args["target_player"]?.stringValue, speaker.rawValue, "the selected speaker leads")
        XCTAssertEqual(
            (sent.args["player_ids_to_add"]?.arrayValue ?? []).compactMap(\.stringValue), [other.id.rawValue])
        XCTAssertNil(sent.args["player_ids_to_remove"], "nothing to ungroup")
    }

    func testFeedFollowsStreamEvents() throws {
        let model = try makeModel()
        XCTAssertEqual(model.thisMacFeed, .local)
        XCTAssertTrue(model.playsLocalQueue)
        model.applyFeed(.streamStarted)
        XCTAssertEqual(model.thisMacFeed, .musicAssistant)
        XCTAssertFalse(model.playsLocalQueue)
        model.applyFeed(.streamStopped)
        XCTAssertEqual(model.thisMacFeed, .local)
        XCTAssertTrue(model.playsLocalQueue)
    }

    /// A speaker has no balance: the refusal is quiet (the marquee already shows the balance text).
    func testRefusedBalanceOnASpeakerIsQuiet() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        try await selectSpeakerWithQueue(model)
        model.clearNotice()
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        let count = server.receivedCommands.count
        model.setBalance(-0.8)
        // Queued after the balance on the one command stream: once the volume reaches the server, the balance's
        // refusal has been handled, so the check is ordered by the stream rather than by a sleep.
        model.setVolume(0.5)
        try await waitUntil("volume_set") {
            server.receivedCommands.dropFirst(count).contains { $0.command == "players/cmd/volume_set" }
        }
        XCTAssertNil(model.notice, "\(String(describing: model.notice))")
    }
}
