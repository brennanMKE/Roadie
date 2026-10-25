import AudioCore
import Foundation
import XCTest

@testable import Roadie

/// `JumpToFileController` (#0176, #0187, #0190, #0210): filtering, which row Play plays, the Queue button and the empty
/// text. Each model is built from an isolated test configuration (temp data directory, defaults suite, no Music
/// Assistant, no discovery), so nothing touches the real defaults, stores, Keychain or network. Nothing plays: the
/// tracks point at files that don't exist, and the player is stopped in `tearDown`.
@MainActor
final class JumpToFileControllerTests: XCTestCase {
    private var suiteNames: [String] = []
    private var folders: [URL] = []
    private var models: [PlayerModel] = []

    override func tearDown() async throws {
        for model in models { model.player.stop() }
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        suiteNames = []
        folders = []
        models = []
    }

    // MARK: Helpers

    private func testConfiguration() throws -> RoadieConfiguration {
        let data = FileManager.default.temporaryDirectory.appending(path: "roadie-jump-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        folders.append(data)
        let suite = "co.sstools.roadie.tests.jump.\(UUID())"
        suiteNames.append(suite)
        var configuration = RoadieConfiguration()
        configuration.dataDirectory = data
        configuration.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        configuration.musicAssistant = .none
        configuration.museum = .fixtures(skinsFolder: data.appending(path: "MuseumSkins", directoryHint: .isDirectory))
        configuration.discovery = false
        configuration.externalOpens = .record
        return configuration
    }

    /// (artist, title, file name) per row, restored stopped with nothing current.
    private func model(_ rows: [(String, String, String)]) throws -> PlayerModel {
        let model = PlayerModel(configuration: try testConfiguration())
        models.append(model)
        model.player.clearQueue()
        let tracks = rows.map { artist, title, file in
            Track(title: title, artist: artist, duration: 90, source: .file(URL(fileURLWithPath: "/nonexistent/roadie-tests/\(file)")))
        }
        if !tracks.isEmpty {
            model.player.restoreQueue(tracks, currentIndex: nil, repeatMode: .off, isShuffled: false)
        }
        return model
    }

    private func controller(_ model: PlayerModel, query: String = "") async -> JumpToFileController {
        let controller = JumpToFileController(model: model)
        controller.rebuild()
        await controller.settle()
        if !query.isEmpty { await search(controller, query) }
        return controller
    }

    private func search(_ controller: JumpToFileController, _ query: String) async {
        controller.query = query
        await controller.settle()
    }

    private static let five = [
        ("Alpha Band", "First", "a.mp3"),
        ("Bravo Band", "Second", "b.mp3"),
        ("Charlie", "Song One", "c.mp3"),
        ("Delta", "Fourth", "d.mp3"),
        ("Echo", "Song Two", "e.mp3"),
    ]

    // MARK: Tests

    func testFilterMatchesWordsAcrossArtistTitleAndFileName() async throws {
        let model = try model([
            ("Tone Artist", "Blue Sky", "x-ray.mp3"),
            ("Other", "Red", "tone-artist-demo.mp3"),
            ("Nobody", "Green", "plain.mp3"),
        ])
        let controller = await controller(model)
        XCTAssertEqual(controller.results.map(\.index), [0, 1, 2], "an empty query lists every row")

        await search(controller, "tone sky")
        XCTAssertEqual(controller.results.map(\.index), [0], "artist and title words")
        XCTAssertEqual(controller.results.first?.name, "Tone Artist - Blue Sky")

        await search(controller, "ray")
        XCTAssertEqual(controller.results.map(\.index), [0], "the file name")

        await search(controller, "TONE")
        XCTAssertEqual(controller.results.map(\.index), [0, 1], "case-insensitive, artist or file name")

        await search(controller, "tone green")
        XCTAssertTrue(controller.results.isEmpty, "every word must match the same row")
    }

    /// The #0187 seam on Jump to File: the second result of a filtered list plays its playlist row (4), not row 1.
    func testPlaySelectedPlaysTheRowNotTheResultIndex() async throws {
        let model = try model(Self.five)
        let controller = await controller(model, query: "song")
        XCTAssertEqual(controller.results.map(\.index), [2, 4])
        XCTAssertEqual(controller.selectedRows, [0], "the first result is selected")
        var closed = 0
        controller.onClose = { closed += 1 }

        controller.selectedRows = [1]
        XCTAssertEqual(controller.selectedResult?.index, 4)
        XCTAssertTrue(controller.playSelected())
        XCTAssertEqual(model.player.queue.currentIndex, 4)
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(model.playlist.isSelected(4), "the playlist editor selects the played row")
    }

    func testPlaySelectedWithNoResultsDoesNothing() async throws {
        let model = try model(Self.five)
        let controller = await controller(model, query: "zzz")
        var closed = 0
        controller.onClose = { closed += 1 }
        XCTAssertFalse(controller.playSelected())
        XCTAssertFalse(controller.toggleQueueSelected())
        XCTAssertNil(model.player.queue.currentIndex)
        XCTAssertEqual(closed, 0)
    }

    func testQueueButtonTitleFollowsTheMarker() async throws {
        let model = try model(Self.five)
        let controller = await controller(model, query: "song")
        XCTAssertTrue(controller.isQueueEnabled)
        XCTAssertEqual(controller.queueButtonTitle, "Queue")
        controller.selectedRows = [1]
        XCTAssertTrue(controller.toggleQueueSelected())
        XCTAssertEqual(model.player.queue.upNextPosition(of: model.player.queue.tracks[4].id), 1)
        XCTAssertEqual(controller.marker(for: 4), "[1]")
        XCTAssertEqual(controller.queueButtonTitle, "Dequeue")
        controller.selectedRows = [0, 1]
        XCTAssertEqual(controller.queueButtonTitle, "Queue", "not every selected result is queued")
        controller.selectedRows = [1]
        XCTAssertTrue(controller.toggleQueueSelected())
        XCTAssertEqual(controller.queueButtonTitle, "Queue")
        XCTAssertEqual(controller.marker(for: 4), "")
        XCTAssertNil(model.player.queue.currentIndex, "queueing doesn't play")
    }

    /// #0190: an empty playlist points at the Library.
    func testEmptyPlaylistTextMentionsTheLibrary() async throws {
        let model = try model([])
        let controller = await controller(model)
        XCTAssertTrue(controller.results.isEmpty)
        let text = try XCTUnwrap(controller.emptyStateText)
        XCTAssertTrue(text.contains("Library"), text)
        XCTAssertTrue(text.contains("\u{2318}L"), text)
        XCTAssertFalse(controller.isQueueEnabled)
    }

    func testNoMatchTextDiffersFromEmpty() async throws {
        let model = try model(Self.five)
        let controller = await controller(model)
        XCTAssertNil(controller.emptyStateText, "nil while there are results")
        await search(controller, "zzz")
        let noMatch = try XCTUnwrap(controller.emptyStateText)
        XCTAssertEqual(noMatch, "No matches")
        XCTAssertFalse(noMatch.contains("Library"))
        XCTAssertFalse(controller.isQueueEnabled)
    }

    /// The panel clamps at both ends (no wrap).
    func testArrowSelectionWrapsOrClamps() async throws {
        let model = try model(Self.five)
        let controller = await controller(model)
        XCTAssertEqual(controller.results.count, 5)
        controller.selectedRows = [0]
        XCTAssertEqual(controller.row(movingBy: -1), 0, "clamped at the top")
        XCTAssertEqual(controller.row(movingBy: 1), 1)
        XCTAssertEqual(controller.row(movingBy: 10), 4, "a page past the end stops on the last row")
        controller.selectedRows = [4]
        XCTAssertEqual(controller.row(movingBy: 1), 4, "clamped at the bottom")
        controller.selectedRows = []
        XCTAssertEqual(controller.row(movingBy: 1), 0, "down with nothing selected picks the first")
        XCTAssertEqual(controller.row(movingBy: -1), 4, "up with nothing selected picks the last")
        await search(controller, "zzz")
        XCTAssertNil(controller.row(movingBy: 1))
    }

    func testSelectionFollowsTheTrackAcrossAQueryChange() async throws {
        let model = try model(Self.five)
        let controller = await controller(model, query: "song")
        controller.selectedRows = [1]  // row 4
        await search(controller, "o")
        XCTAssertEqual(controller.selectedResult?.index, 4, "the same track stays selected")
    }
}
