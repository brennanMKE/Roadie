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
    /// One dispatch row. `prepare` runs just before `perform` and returns the effect the command must have; the effect
    /// must not hold yet (so a case wired to nothing fails), and must hold within the wait after `perform`.
    struct Row {
        enum Target { case local, speaker }
        var target: Target = .local
        var prepare: (PlayerModel) throws -> (() -> Bool)
    }

    /// A row whose effect is a recorded `SystemRequest`: exactly one more, and it is `request`.
    func requested(_ request: PlayerModel.SystemRequest) -> Row {
        Row { _ in
            let count = self.systemRequests.count
            return { self.systemRequests.count == count + 1 && self.systemRequests.last == request }
        }
    }

    /// A row whose effect is `state` turning true on the model.
    func becomes(_ state: @escaping (PlayerModel) -> Bool) -> Row {
        Row { m in { state(m) } }
    }

    /// A row run on the playing scripted speaker whose effect is `command` reaching the server after `perform`
    /// (and, when given, `check` holding for that request's arguments).
    func sends(
        _ command: String, to server: ScriptedMusicAssistant,
        where check: @escaping (PlayerModel) -> (SentRequest) -> Bool = { _ in { _ in true } }
    ) -> Row {
        Row(target: .speaker) { m in
            let count = server.receivedCommands.count
            let matches = check(m)
            return { server.receivedCommands.dropFirst(count).contains { $0.command == command && matches($0) } }
        }
    }

    /// Runs `rows` in order on `local` or `speaker`: each effect is false before its `perform`, true after.
    func run<Command>(
        _ rows: [(Command, Row)], local: PlayerModel, speaker: PlayerModel, perform: (PlayerModel, Command) -> Void
    ) async throws {
        for (command, row) in rows {
            let model = row.target == .local ? local : speaker
            let effect = try row.prepare(model)
            XCTAssertFalse(effect(), "\(command): the effect already holds, so a no-op would pass")
            perform(model, command)
            try await waitUntil("\(command)'s effect") { effect() }
        }
    }

    /// A `.queueLoaded` model with the scripted speaker selected, playing and seekable.
    func playingSpeaker() async throws -> (PlayerModel, ScriptedMusicAssistant) {
        let model = try makeModel(scenario: .queueLoaded)
        let server = try XCTUnwrap(model.scriptedMusicAssistant)
        let speaker = try await selectSpeakerWithQueue(model)
        try await waitUntil("the speaker plays") { model.nowPlaying.output == speaker && model.nowPlaying.state == .playing }
        try await waitUntil("a seekable position") { model.positionFraction != nil }
        return (model, server)
    }

    /// The transport rows both tables share: each sends its own Music Assistant command to the speaker.
    /// `pause()` sends `.togglePlayPause`, which the backend sends as `play_pause`.
    func transportRows(_ server: ScriptedMusicAssistant) -> [String: Row] {
        [
            "previous": sends("player_queues/previous", to: server),
            "play": sends("players/cmd/play", to: server),
            "pause": sends("players/cmd/play_pause", to: server),
            "stop": sends("players/cmd/stop", to: server),
            "next": sends("player_queues/next", to: server),
        ]
    }

    /// Every `MainMenuCommand` has a row; a new case without one fails here.
    func testMainMenuCommandsDispatch() async throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        let (speaker, server) = try await playingSpeaker()
        let transport = transportRows(server)
        var updateChecks = 0
        var table: [MainMenuCommand: Row] = [:]
        table[.about] = requested(.about)
        table[.checkForUpdates] = Row { m in
            m.updateActions = (canCheck: { true }, check: { updateChecks += 1 })
            let before = updateChecks
            return { updateChecks == before + 1 }
        }
        table[.openFiles] = requested(.openFiles(replace: true))
        table[.addFiles] = requested(.openFiles(replace: false))
        table[.toggleEQWindow] = becomes { $0.isEQWindowOpen }
        table[.togglePlaylistWindow] = becomes { $0.isPlaylistWindowOpen }
        table[.toggleLibraryWindow] = requested(.library)
        table[.openSkin] = requested(.openSkin)
        table[.timeElapsed] = Row { m in
            m.timeMode = .remaining
            return { m.timeMode == .elapsed }
        }
        table[.timeRemaining] = becomes { $0.timeMode == .remaining }
        table[.toggleAlwaysOnTop] = becomes { $0.isAlwaysOnTop }
        table[.toggleDoubleSize] = becomes { $0.isDoubleSize && $0.scale == PlayerModel.baseScale * 2 }
        table[.toggleMainShade] = becomes { $0.isMainWindowShaded }
        table[.toggleEQShade] = becomes { $0.isEQWindowShaded }
        table[.togglePlaylistShade] = becomes { $0.isPlaylistWindowShaded }
        table[.toggleRepeat] = becomes { $0.isRepeating }
        table[.toggleShuffle] = becomes { $0.isShuffled }
        table[.previous] = transport["previous"]
        table[.play] = transport["play"]
        table[.pause] = transport["pause"]
        table[.stop] = transport["stop"]
        table[.next] = transport["next"]
        table[.jumpToFile] = requested(.jumpToFile)
        table[.quit] = requested(.quit)
        // CRASH CHECKS ONLY, not dispatch checks: no skins are indexed in a test model, so next, previous and random
        // skin are no-ops whatever they're wired to. Seeding an index is a follow-up (issues/0211.md ## Follow-ups).
        let crashChecksOnly: [MainMenuCommand] = [.nextSkin, .previousSkin, .randomSkin]

        let missing = MainMenuCommand.allCases.filter { table[$0] == nil && !crashChecksOnly.contains($0) }
        XCTAssertEqual(missing, [], "commands without a row")
        for command in crashChecksOnly {
            model.perform(command)
            XCTAssertFalse(model.skinBrowser.canNavigate)
        }
        let rows = MainMenuCommand.allCases.compactMap { command in table[command].map { (command, $0) } }
        try await run(rows, local: model, speaker: speaker) { $0.perform($1) }
        XCTAssertEqual(updateChecks, 1)
    }

    /// All 13 hotkeys. Seek and transport run on the playing scripted speaker and check the command each sends; the
    /// seeks go first, while there is a position to seek from.
    func testHotkeysDispatch() async throws {
        let model = try makeModel()
        restoreThreeTracks(model)
        let (speaker, server) = try await playingSpeaker()
        let transport = transportRows(server)
        XCTAssertEqual(WinampHotkey.allCases.count, 13)
        func seek(forward: Bool) -> Row {
            sends("players/cmd/seek", to: server) { m in
                let status = m.mainWindowStatus
                let target = WinampHotkeys.seekTarget(elapsed: status.elapsed, duration: status.duration, forward: forward)
                XCTAssertNotNil(target, "no duration to seek within")
                return { sent in
                    guard let target, let position = sent.args["position"]?.doubleValue else { return false }
                    return abs(position - target) <= 1  // the backend rounds to whole seconds
                }
            }
        }
        func nudge(up: Bool) -> Row {
            Row { m in
                m.setVolume(0.5)  // away from both ends, so a nudge always changes it
                let expected = WinampHotkeys.nudgedVolume(m.volume, up: up)
                return { abs(m.volume - expected) < 0.0001 }
            }
        }
        var table: [WinampHotkey: Row] = [:]
        table[.seekBack] = seek(forward: false)
        table[.seekForward] = seek(forward: true)
        table[.volumeDown] = nudge(up: false)
        table[.volumeUp] = nudge(up: true)
        table[.toggleShuffle] = becomes { $0.isShuffled }
        table[.toggleRepeat] = becomes { $0.isRepeating }
        table[.openFile] = requested(.openFiles(replace: true))
        table[.jumpToFile] = requested(.jumpToFile)
        table[.previous] = transport["previous"]
        table[.play] = transport["play"]
        table[.pause] = transport["pause"]
        table[.stop] = transport["stop"]
        table[.next] = transport["next"]

        let missing = WinampHotkey.allCases.filter { table[$0] == nil }
        XCTAssertEqual(missing.map { "\($0)" }, [], "hotkeys without a row")
        let order: [WinampHotkey] = [.seekBack, .seekForward] + WinampHotkey.allCases.filter {
            $0 != .seekBack && $0 != .seekForward
        }
        let rows = order.compactMap { hotkey in table[hotkey].map { (hotkey, $0) } }
        try await run(rows, local: model, speaker: speaker) { $0.perform($1) }
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
        XCTAssertFalse(state.canCheckForUpdates, "no updater")
        model.updateActions = (canCheck: { true }, check: {})
        XCTAssertTrue(model.mainMenuState.canCheckForUpdates)
    }
}
