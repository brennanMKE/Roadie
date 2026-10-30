import Foundation
import LibraryBrowser
import MusicAssistantKitStub
import MusicBackendKit
import XCTest

@testable import Roadie

/// Playback › Save Queue as Playlist… on a Music Assistant speaker (#0218), against the scripted server, with
/// `queueNameOverride` answering the name prompt. Also the picker's filter and the name rule, on their own.
@MainActor
final class QueueSaveTests: PlayerModelTestCase {
    private var prompts = 0

    override func tearDown() async throws {
        prompts = 0
        try await super.tearDown()
    }

    private func answerName(_ model: PlayerModel, with name: String?) {
        model.queueNameOverride = { [weak self] in
            self?.prompts += 1
            return name
        }
    }

    private func saves(_ server: ScriptedMusicAssistant) -> [SentRequest] {
        server.receivedCommands.filter { $0.command == "player_queues/save_as_playlist" }
    }

    func testSaveQueueToSpeakerPlaylist() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        let speaker = try await selectSpeakerWithQueue(model)
        XCTAssertTrue(model.canSaveQueue)

        answerName(model, with: "Road Trip")
        model.saveQueue()
        try await waitUntil("the saved notice") { model.notice?.text == "Saved queue as \u{201C}Road Trip\u{201D}" }
        let sent = saves(server)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.args["queue_id"]?.stringValue, speaker.rawValue)
        XCTAssertEqual(sent.first?.args["name"]?.stringValue, "Road Trip")
        XCTAssertEqual(prompts, 1)
    }

    func testSaveQueueCancelledOrFailed() async throws {
        // `.refused` needs a remote backend without queue editing; the router's remote is always Music Assistant,
        // which has it, so that branch can't be reached from `PlayerModel` (QueueSaveTargetTests covers the choice).
        let model = try makeModel(scenario: .libraryIdle)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        let speaker = try await connectedSpeaker(model)
        model.selectOutput(speaker)

        // Cancelled, then a save with a name: once the second one's reply is in, the cancelled one sent nothing.
        answerName(model, with: nil)
        model.saveQueue()
        answerName(model, with: "Empty")
        model.saveQueue()
        // The speaker's queue is empty, so the server refuses.
        try await waitUntil("the failure notice") { model.notice?.text == "Couldn't save the queue" }
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(saves(server).count, 1)
        XCTAssertEqual(saves(server).first?.args["name"]?.stringValue, "Empty")
        XCTAssertNotNil(model.notice?.detail)
    }

    func testQueueNameIsTrimmed() {
        XCTAssertEqual(SaveQueueSheet.playlistName(from: "  Road Trip \n"), "Road Trip")
        XCTAssertEqual(SaveQueueSheet.playlistName(from: "Mix"), "Mix")
        XCTAssertNil(SaveQueueSheet.playlistName(from: ""))
        XCTAssertNil(SaveQueueSheet.playlistName(from: " \t\n "))
    }

    func testPlaylistPickerFilters() {
        let mine = LibraryPlaylist(id: MediaID(.playlist, "1"), name: "Road Trip", isEditable: true)
        let built = LibraryPlaylist(id: MediaID(.playlist, "2"), name: "Recently Added", source: .builtIn)
        let spotify = LibraryPlaylist(id: MediaID(.playlist, "3"), name: "Daily ROAD Mix", source: .provider(name: "Spotify"))
        let all = [mine, built, spotify]

        XCTAssertEqual(PlaylistPickerSheet.matching(all, search: ""), all)
        XCTAssertEqual(PlaylistPickerSheet.matching(all, search: "   "), all)
        XCTAssertEqual(PlaylistPickerSheet.matching(all, search: " road "), [mine, spotify])
        XCTAssertEqual(PlaylistPickerSheet.matching(all, search: "nothing"), [])

        let matching = PlaylistPickerSheet.matching(all, search: "road")
        XCTAssertEqual(PlaylistGrouping.groups(matching).map(\.title), ["My Playlists", "Spotify · read-only"])
        XCTAssertEqual(PlaylistPickerSheet.chosen(in: matching, selection: spotify.id), spotify)
        XCTAssertNil(PlaylistPickerSheet.chosen(in: matching, selection: built.id), "filtered out")
        XCTAssertNil(PlaylistPickerSheet.chosen(in: matching, selection: nil))
    }
}
