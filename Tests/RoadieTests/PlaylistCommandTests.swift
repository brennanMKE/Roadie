import AppKit
import SkinKit
import XCTest

@testable import Roadie

/// The playlist editor's commands (#0226): `PlayerModel.perform(_: PlaylistCommand)` and `playlistMenuState`, which
/// the skinned pop-ups and the menu bar's Playlist menu share.
@MainActor
final class PlaylistCommandTests: PlayerModelTestCase {
    func testEveryCommandDispatches() throws {
        let model = try makeModel()
        model.perform(PlaylistCommand.addFile)
        model.perform(PlaylistCommand.addFolder)
        XCTAssertEqual(Array(systemRequests.prefix(2)), [.openFiles(replace: false), .openFolder])

        model.perform(PlaylistCommand.loadPlaylist)
        // The local queue opens a playlist file, or offers Library Playlist… / Playlist File… when the Library has some.
        XCTAssertTrue(
            systemRequests.contains(.openPlaylistFile) || popUps.last?.titles == ["Library Playlist…", "Playlist File…"],
            "Load Playlist… did nothing: \(systemRequests), \(popUps.map(\.titles))")

        restoreThreeTracks(model)
        let playlist = model.playlist
        let titles = { playlist.tracks.map(\.title) }
        XCTAssertEqual(titles(), ["Tone A", "Tone B", "Tone C"])
        var state = model.playlistMenuState
        XCTAssertTrue(state.hasRows)
        XCTAssertFalse(state.hasSelection)
        XCTAssertFalse(state.isRemote)

        model.perform(PlaylistCommand.reverse)
        XCTAssertEqual(titles(), ["Tone C", "Tone B", "Tone A"])
        model.perform(PlaylistCommand.sortByTitle)
        XCTAssertEqual(titles(), ["Tone A", "Tone B", "Tone C"])

        model.perform(PlaylistCommand.invertSelection)
        XCTAssertTrue((0..<3).allSatisfy(playlist.isSelected))
        model.perform(PlaylistCommand.selectNone)
        XCTAssertFalse((0..<3).contains(where: playlist.isSelected))
        playlist.click(1)
        state = model.playlistMenuState
        XCTAssertTrue(state.hasSelection)
        XCTAssertTrue(state.hasFileInfo)
        XCTAssertTrue(PlaylistMenu.item(.crop, state).isEnabled)

        model.perform(PlaylistCommand.crop)
        XCTAssertEqual(titles(), ["Tone B"])
        model.perform(PlaylistCommand.clearPlaylist)
        XCTAssertEqual(titles(), [])
        state = model.playlistMenuState
        XCTAssertFalse(state.hasRows)
        XCTAssertFalse(PlaylistMenu.item(.clearPlaylist, state).isEnabled)
    }

    func testStateOnAMusicAssistantQueue() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        try await selectSpeakerWithQueue(model)
        let state = model.playlistMenuState
        XCTAssertTrue(state.isRemote)
        XCTAssertTrue(state.hasRows)
        for command in [PlaylistCommand.sortByTitle, .sortByFileName, .sortByPath, .reverse, .randomize] {
            XCTAssertFalse(PlaylistMenu.item(command, state).isEnabled, "\(command)")
        }
        XCTAssertTrue(PlaylistMenu.item(.savePlaylist, state).isEnabled)
        XCTAssertTrue(PlaylistMenu.item(.loadPlaylist, state).isEnabled)
        XCTAssertTrue(PlaylistMenu.item(.clearPlaylist, state).isEnabled)
    }
}

/// `PlaylistMenuBuilder` (#0226), like `MainMenuBuilder`.
@MainActor
final class PlaylistMenuBuilderTests: XCTestCase {
    func testBuildsTitlesEnabledAndShortcuts() throws {
        var ran: [PlaylistCommand] = []
        let state = PlaylistMenuState(hasRows: true, canLoad: true)
        let menu = PlaylistMenuBuilder.menu(PlaylistMenu.menuBarEntries(state)) { ran.append($0) }
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, PlaylistCommand.allCases.count)
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 4)
        XCTAssertFalse(menu.autoenablesItems)

        let crop = try XCTUnwrap(items.first { $0.title == "Crop" })
        XCTAssertFalse(crop.isEnabled)
        let load = try XCTUnwrap(items.first { $0.title == "Load Playlist…" })
        XCTAssertTrue(load.isEnabled)
        XCTAssertEqual(load.keyEquivalent, "l")
        XCTAssertEqual(load.keyEquivalentModifierMask, [.command, .option])
        let sort = try XCTUnwrap(items.first { $0.title == "Sort by Path and File Name" })
        XCTAssertEqual(sort.keyEquivalent, "3")
        XCTAssertEqual(sort.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(try XCTUnwrap(items.first { $0.title == "Reverse List" }).keyEquivalent, "")

        let index = menu.index(of: sort)
        menu.performActionForItem(at: index)
        XCTAssertEqual(ran, [.sortByPath])
    }
}
