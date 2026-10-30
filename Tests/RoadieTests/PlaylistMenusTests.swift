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
        let info = { try XCTUnwrap(menu.items.first { $0.title == "File Info…" }) }
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Play", "Queue", "", "Remove", "File Info…", "", "Load Playlist…", "Clear Playlist"])
        XCTAssertTrue(try info().isEnabled)

        model.playlist.toggleQueueForSelection()
        menu = PlaylistContextMenus.rowMenu(model)
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Play", "Dequeue", "Clear Queue", "", "Remove", "File Info…", "", "Load Playlist…", "Clear Playlist"])

        model.playlist.selectNone()
        model.player.clearQueue()
        menu = PlaylistContextMenus.rowMenu(model)
        XCTAssertFalse(try info().isEnabled, "File Info… needs a selected row or a current track")
    }

    private func fire(_ menu: NSMenu, _ title: String) throws {
        let item = try XCTUnwrap(menu.items.first { $0.title == title })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
    }

    func testEmptyAreaMenu() throws {
        let model = try makeModel(folder: true)
        var menu = PlaylistContextMenus.emptyAreaMenu(model)
        XCTAssertEqual(menu.items.map(\.title), ["Load Playlist…", "Clear Playlist"])
        XCTAssertFalse(menu.items[1].isEnabled, "nothing to clear on an empty list")
        XCTAssertTrue(menu.items[0].isEnabled)
        try fire(menu, "Load Playlist…")
        XCTAssertEqual(systemRequests.last, .openPlaylistFile)

        restoreThreeTracks(model)
        menu = PlaylistContextMenus.emptyAreaMenu(model)
        XCTAssertTrue(menu.items[1].isEnabled)
        try fire(menu, "Clear Playlist")
        XCTAssertTrue(model.playlist.tracks.isEmpty)
    }

    func testContextLoadOnAMusicAssistantQueueOpensThePicker() async throws {
        let model = try makeModel(scenario: .queueLoaded)
        try await selectSpeakerWithQueue(model)
        model.isPickingPlaylist = false
        try fire(PlaylistContextMenus.emptyAreaMenu(model), "Load Playlist…")
        XCTAssertTrue(model.isPickingPlaylist)
    }

    /// Regression (#0229): the right-click menu ends with Load Playlist… and Clear Playlist.
    func testRowMenuOffersLoadAndClear() throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        model.playlist.click(1)
        let menu = PlaylistContextMenus.rowMenu(model)
        XCTAssertEqual(Array(menu.items.map(\.title).suffix(3)), ["", "Load Playlist…", "Clear Playlist"])
        let clear = try XCTUnwrap(menu.items.first { $0.title == "Clear Playlist" })
        XCTAssertTrue(clear.isEnabled)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == "Load Playlist…" }).isEnabled)
        let action = try XCTUnwrap(clear.action)
        NSApp.sendAction(action, to: clear.target, from: clear)
        XCTAssertTrue(model.playlist.tracks.isEmpty)
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

/// The skins folder setting (#0211). The default folder (`applyDefaultFolderIfNeeded`, #0169) is checked at a
/// `defaultFolderURL` inside the test's data directory (#0209), never under the user's home.
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

    /// #0209: with no folder set, the default folder is created and stored.
    func testApplyDefaultFolderCreatesAndStoresTheDefault() throws {
        let configuration = try testConfiguration()
        let data = try XCTUnwrap(configuration.dataDirectory)
        let folder = data.appending(path: "Home/Roadie/Skins", directoryHint: .isDirectory)
        let path = folder.path(percentEncoded: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let library = SkinLibraryModel(
            defaults: configuration.defaults, databaseURL: data.appending(path: "skins.sqlite"),
            defaultFolderURL: folder, startupDelay: .seconds(3600))
        XCTAssertTrue(library.applyDefaultFolderIfNeeded())
        library.cancel()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), "\(path) wasn't created")
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(library.folderPath, path)
        XCTAssertEqual(configuration.defaults.string(forKey: SkinLibraryModel.folderKey), path)
    }

    /// #0209: a test configuration's default skins folder is `<data>/Roadie/Skins`, so a UI test's fresh install never
    /// creates `~/Roadie/Skins`.
    func testTestConfigurationDefaultSkinsFolderIsInItsDataDirectory() throws {
        let configuration = try testConfiguration()
        let data = try XCTUnwrap(configuration.dataDirectory)
        XCTAssertEqual(
            configuration.defaultSkinsFolder.standardizedFileURL.path(percentEncoded: false),
            data.appending(path: "Roadie/Skins", directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false))
    }
}
