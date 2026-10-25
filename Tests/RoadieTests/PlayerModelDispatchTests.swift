import AudioCore
import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import SkinKit
import XCTest

@testable import Roadie

/// The main menu's and the Winamp hotkeys' one switch onto the model (#0211). Panels, About, Quit, Jump to File and
/// the Library window are captured by `systemRequestOverride`, so nothing shows and nothing writes to `.standard`.
@MainActor
final class PlayerModelDispatchTests: PlayerModelTestCase {
    /// Every `MainMenuCommand` has a row; a new case without one fails here.
    func testMainMenuCommandsDispatch() async throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        typealias Check = (PlayerModel) async throws -> Void
        let requested = { (request: PlayerModel.SystemRequest) -> Check in
            { _ in XCTAssertEqual(self.systemRequests.last, request) }
        }
        // (command, check after perform). Checks read the state the command must have changed.
        var table: [MainMenuCommand: Check] = [:]
        table[.about] = requested(.about)
        table[.checkForUpdates] = { m in XCTAssertNil(m.updateActions) }  // no updater in a test: a no-op
        table[.openFiles] = requested(.openFiles(replace: true))
        table[.addFiles] = requested(.openFiles(replace: false))
        table[.toggleEQWindow] = { m in XCTAssertTrue(m.isEQWindowOpen) }
        table[.togglePlaylistWindow] = { m in XCTAssertTrue(m.isPlaylistWindowOpen) }
        table[.toggleLibraryWindow] = requested(.library)
        table[.openSkin] = requested(.openSkin)
        // No skins indexed: navigation is a no-op and must not crash.
        table[.nextSkin] = { m in XCTAssertFalse(m.skinBrowser.canNavigate) }
        table[.previousSkin] = { m in XCTAssertFalse(m.skinBrowser.canNavigate) }
        table[.randomSkin] = { m in XCTAssertFalse(m.skinBrowser.canNavigate) }
        table[.timeElapsed] = { m in XCTAssertEqual(m.timeMode, .elapsed) }
        table[.timeRemaining] = { m in XCTAssertEqual(m.timeMode, .remaining) }
        table[.toggleAlwaysOnTop] = { m in XCTAssertTrue(m.isAlwaysOnTop) }
        table[.toggleDoubleSize] = { m in
            XCTAssertTrue(m.isDoubleSize)
            XCTAssertEqual(m.scale, PlayerModel.baseScale * 2)
        }
        table[.toggleMainShade] = { m in XCTAssertTrue(m.isMainWindowShaded) }
        table[.toggleEQShade] = { m in XCTAssertTrue(m.isEQWindowShaded) }
        table[.togglePlaylistShade] = { m in XCTAssertTrue(m.isPlaylistWindowShaded) }
        table[.toggleRepeat] = { m in try await self.waitUntil("repeat on") { m.isRepeating } }
        table[.toggleShuffle] = { m in try await self.waitUntil("shuffle on") { m.isShuffled } }
        // Transport on a queue whose files don't exist: the command reaches the local player, which stays put or fails
        // to load; the local queue is still the one shown.
        let transport: Check = { m in XCTAssertTrue(m.playsLocalQueue) }
        table[.previous] = transport
        table[.play] = transport
        table[.pause] = transport
        table[.stop] = { m in try await self.waitUntil("stopped") { m.player.state == .stopped } }
        table[.next] = transport
        table[.jumpToFile] = requested(.jumpToFile)
        table[.quit] = requested(.quit)

        let missing = MainMenuCommand.allCases.filter { table[$0] == nil }
        XCTAssertEqual(missing, [], "commands without a check")
        for command in MainMenuCommand.allCases {
            model.perform(command)
            try await table[command]?(model)
        }
    }

    func testHotkeysDispatch() async throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        XCTAssertEqual(WinampHotkey.allCases.count, 13)
        var checked: Set<String> = []
        func run(_ hotkey: WinampHotkey, _ check: () async throws -> Void) async throws {
            model.perform(hotkey)
            try await check()
            checked.insert("\(hotkey)")
        }
        // Stopped, so there is no position: the seek keys are a no-op rather than a jump.
        try await run(.seekBack) { XCTAssertNil(model.positionFraction) }
        try await run(.seekForward) { XCTAssertNil(model.positionFraction) }
        let volume = model.volume
        try await run(.volumeDown) { XCTAssertEqual(model.volume, WinampHotkeys.nudgedVolume(volume, up: false)) }
        try await run(.volumeUp) { XCTAssertEqual(model.volume, volume, accuracy: 0.0001) }
        try await run(.toggleShuffle) { try await self.waitUntil("shuffle on") { model.isShuffled } }
        try await run(.toggleRepeat) { try await self.waitUntil("repeat on") { model.isRepeating } }
        try await run(.openFile) { XCTAssertEqual(self.systemRequests.last, .openFiles(replace: true)) }
        try await run(.jumpToFile) { XCTAssertEqual(self.systemRequests.last, .jumpToFile) }
        for hotkey in [WinampHotkey.previous, .play, .pause, .next] {
            try await run(hotkey) { XCTAssertTrue(model.playsLocalQueue) }
        }
        try await run(.stop) { try await self.waitUntil("stopped") { model.player.state == .stopped } }
        XCTAssertEqual(checked.count, WinampHotkey.allCases.count)
    }

    func testMainMenuStateFollowsTheModel() throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        XCTAssertEqual(model.mainMenuState.isMainShaded, false)
        model.toggleMainWindowShade()
        model.toggleEQWindowShade()
        model.togglePlaylistWindowShade()
        model.toggleAlwaysOnTop()
        let state = model.mainMenuState
        XCTAssertTrue(state.isMainShaded)
        XCTAssertTrue(state.isEQShaded)
        XCTAssertTrue(state.isPlaylistShaded)
        XCTAssertTrue(state.isAlwaysOnTop)
        XCTAssertEqual(state.isRepeating, model.isRepeating)
        XCTAssertEqual(state.isShuffled, model.isShuffled)
        XCTAssertEqual(state.canNavigateSkins, model.skinBrowser.canNavigate)
        XCTAssertFalse(state.canCheckForUpdates)
    }
}
