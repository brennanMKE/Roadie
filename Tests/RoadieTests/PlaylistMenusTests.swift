import AppKit
import Foundation
import XCTest

@testable import Roadie

/// The playlist's right-click, SORT and MISC menus (#0211), read through `PlaylistContextMenus.popUpOverride`.
@MainActor
final class PlaylistMenusTests: PlayerModelTestCase {
    func testRowMenuTitlesFollowTheSelection() throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        model.playlist.click(1)
        var menu = PlaylistContextMenus.rowMenu(model)
        XCTAssertEqual(menu.items.map(\.title), ["Play", "Queue", "", "Remove", "File Info…"])
        XCTAssertTrue(try XCTUnwrap(menu.items.last).isEnabled)

        model.playlist.toggleQueueForSelection()
        menu = PlaylistContextMenus.rowMenu(model)
        XCTAssertEqual(menu.items.map(\.title), ["Play", "Dequeue", "Clear Queue", "", "Remove", "File Info…"])

        model.playlist.selectNone()
        model.player.clearQueue()
        menu = PlaylistContextMenus.rowMenu(model)
        XCTAssertFalse(try XCTUnwrap(menu.items.last).isEnabled, "File Info… needs a selected row or a current track")
    }

    func testSortMenuIsDisabledOnRemote() async throws {
        let local = try makeModel()
        restoreThreeTracks(local)
        PlaylistContextMenus.sort(local)
        XCTAssertEqual(popUps.last?.enabled, true)
        XCTAssertEqual(popUps.last?.titles.count, 6)

        let model = try makeModel(scenario: .queueLoaded)
        try await selectSpeakerWithQueue(model)
        model.clearNotice()
        PlaylistContextMenus.sort(model)
        XCTAssertEqual(popUps.last?.enabled, false)
        XCTAssertEqual(model.notice?.text, "Not for Music Assistant queues")
    }

    func testMiscOptionsHasGenerateHTML() throws {
        let model = try makeModel()
        PlaylistContextMenus.miscOptions(model)
        XCTAssertEqual(popUps.last?.titles, ["Generate HTML Playlist"])
    }

    /// #0230: the pop-ups open in the playlist window's view while it's visible, else the key window's.
    func testPopUpViewPrefersTheVisiblePlaylistWindow() {
        let playlist = NSView()
        let key = NSView()
        XCTAssertIdentical(PlaylistContextMenus.popUpView(playlist: playlist, playlistVisible: true, key: key), playlist)
        XCTAssertIdentical(PlaylistContextMenus.popUpView(playlist: playlist, playlistVisible: false, key: key), key)
        XCTAssertIdentical(PlaylistContextMenus.popUpView(playlist: nil, playlistVisible: true, key: key), key)
        XCTAssertNil(PlaylistContextMenus.popUpView(playlist: nil, playlistVisible: false, key: nil))
        XCTAssertNil(PlaylistContextMenus.popUpView(playlist: playlist, playlistVisible: false, key: nil))
    }

    /// #0230: the pointer maps into the (flipped) hosting view, so the menu opens at the pointer, not a window
    /// height away.
    func testPopUpPointIsThePointerInTheHostView() {
        final class FlippedView: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 400), styleMask: .borderless,
                              backing: .buffered, defer: true)
        let view = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = view
        // 10 pt in from the window's left and 10 pt down from its top (screen y grows upward).
        XCTAssertEqual(PlaylistContextMenus.point(NSPoint(x: 110, y: 590), in: view), NSPoint(x: 10, y: 10))
        XCTAssertEqual(PlaylistContextMenus.point(NSPoint(x: 400, y: 200), in: view), NSPoint(x: 300, y: 400))
        let unflipped = NSView(frame: view.bounds)
        window.contentView = unflipped
        XCTAssertEqual(PlaylistContextMenus.point(NSPoint(x: 110, y: 590), in: unflipped), NSPoint(x: 10, y: 390))
    }
}

/// The skins folder setting (#0211). The real default folder (`applyDefaultFolderIfNeeded`) is under the user's home,
/// so only an already-set folder is checked here.
@MainActor
final class SkinLibraryModelTests: PlayerModelTestCase {
    func testFolderSetAndClear() throws {
        let configuration = try testConfiguration()
        let folder = try temporaryDirectory("roadie-skins")
        let library = SkinLibraryModel(
            defaults: configuration.defaults,
            databaseURL: try XCTUnwrap(configuration.dataDirectory).appending(path: "skins.sqlite"))
        XCTAssertFalse(library.hasFolder)
        XCTAssertEqual(library.countsText, "No folder chosen")
        library.setFolder(folder.path)
        XCTAssertTrue(library.hasFolder)
        XCTAssertEqual(configuration.defaults.string(forKey: SkinLibraryModel.folderKey), folder.path)
        library.cancel()
        library.setFolder(nil)
        XCTAssertFalse(library.hasFolder)
        XCTAssertNil(configuration.defaults.string(forKey: SkinLibraryModel.folderKey))
    }

    func testApplyDefaultFolderKeepsASetFolder() throws {
        let configuration = try testConfiguration()
        let folder = try temporaryDirectory("roadie-skins")
        configuration.defaults.set(folder.path, forKey: SkinLibraryModel.folderKey)
        let library = SkinLibraryModel(
            defaults: configuration.defaults,
            databaseURL: try XCTUnwrap(configuration.dataDirectory).appending(path: "skins.sqlite"),
            startupDelay: .seconds(3600))
        XCTAssertTrue(library.applyDefaultFolderIfNeeded())
        XCTAssertEqual(library.folderPath, folder.path)
    }
}
