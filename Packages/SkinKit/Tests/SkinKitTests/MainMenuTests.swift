import Testing
@testable import SkinKit

struct MainMenuTests {
    private func items(_ entries: [MainMenuEntry]) -> [MainMenuItem] {
        entries.flatMap { entry -> [MainMenuItem] in
            switch entry {
            case .item(let item): [item]
            case .separator: []
            case .submenu(_, let children): items(children)
            }
        }
    }

    private func item(_ command: MainMenuCommand, _ state: MainMenuState = MainMenuState()) -> MainMenuItem? {
        items(MainMenu.entries(state)).first { $0.command == command }
    }

    @Test func topLevelOrder() {
        let labels = MainMenu.entries(MainMenuState()).map { entry -> String in
            switch entry {
            case .item(let item): item.title
            case .separator: "-"
            case .submenu(let title, _): "\(title) >"
            }
        }
        #expect(
            labels == [
                "About Roadie", "Check for Updates…", "-", "Play File…", "Add to Playlist…", "-", "Equalizer", "Playlist Editor", "Media Library", "-",
                "Skins >", "Options >", "Playback >", "Visualization >", "-", "Exit",
            ])
    }

    @Test func checkForUpdatesFollowsAbout() {
        let commands = items(MainMenu.entries(MainMenuState())).map(\.command)
        #expect(Array(commands.prefix(2)) == [.about, .checkForUpdates])
        #expect(item(.checkForUpdates)?.isEnabled == false)
        #expect(item(.checkForUpdates, MainMenuState(canCheckForUpdates: true))?.isEnabled == true)
    }

    @Test func timeModeRadioChecksCurrentMode() {
        let elapsed = MainMenuState(timeMode: .elapsed)
        #expect(item(.timeElapsed, elapsed)?.state == .on)
        #expect(item(.timeRemaining, elapsed)?.state == .off)
        let remaining = MainMenuState(timeMode: .remaining)
        #expect(item(.timeElapsed, remaining)?.state == .off)
        #expect(item(.timeRemaining, remaining)?.state == .on)
    }

    @Test func windowTogglesReflectState() {
        #expect(item(.toggleEQWindow)?.state == .off)
        #expect(item(.togglePlaylistWindow)?.state == .off)
        let open = MainMenuState(isEQWindowOpen: true, isPlaylistWindowOpen: true)
        #expect(item(.toggleEQWindow, open)?.state == .on)
        #expect(item(.togglePlaylistWindow, open)?.state == .on)
        #expect(item(.toggleLibraryWindow)?.state == .off)
        #expect(item(.toggleLibraryWindow, MainMenuState(isLibraryWindowOpen: true))?.state == .on)
    }

    @Test func shadeRepeatShuffleChecksReflectState() {
        let off = MainMenuState()
        let on = MainMenuState(
            isMainShaded: true, isEQShaded: true, isPlaylistShaded: true, isRepeating: true, isShuffled: true,
            isAlwaysOnTop: true, isDoubleSize: true)
        for command in [MainMenuCommand.toggleAlwaysOnTop, .toggleDoubleSize, .toggleMainShade, .toggleEQShade, .togglePlaylistShade, .toggleRepeat, .toggleShuffle] {
            #expect(item(command, off)?.state == .off)
            #expect(item(command, on)?.state == .on)
        }
    }

    @Test func skinNavigationDisabledWithoutIndex() {
        let none = MainMenuState(canNavigateSkins: false)
        for command in [MainMenuCommand.nextSkin, .previousSkin, .randomSkin] {
            #expect(item(command, none)?.isEnabled == false)
            #expect(item(command, MainMenuState(canNavigateSkins: true))?.isEnabled == true)
        }
        #expect(item(.openSkin, none)?.isEnabled == true)
    }

    @Test func everyCommandAppearsOnce() {
        let commands = items(MainMenu.entries(MainMenuState())).map(\.command)
        #expect(Set(commands).count == commands.count)
        #expect(commands.count == 29)
    }

    @Test func unsupportedEntriesAreAbsent() {
        let titles = items(MainMenu.entries(MainMenuState())).map(\.title)
        for missing in ["Play Location"] {
            #expect(!titles.contains(missing))
        }
    }

    @Test func shortcutsMatchMenuBar() {
        #expect(item(.openFiles)?.shortcut == MainMenuShortcut("o"))
        #expect(item(.addFiles)?.shortcut == MainMenuShortcut("o", [.command, .option]))
        #expect(item(.openSkin)?.shortcut == MainMenuShortcut("o", [.command, .shift]))
        #expect(item(.toggleEQWindow)?.shortcut == MainMenuShortcut("2"))
        #expect(item(.togglePlaylistWindow)?.shortcut == MainMenuShortcut("3"))
        #expect(item(.toggleLibraryWindow)?.shortcut == MainMenuShortcut("l"))
        #expect(item(.toggleMainShade)?.shortcut == MainMenuShortcut("w", [.command, .control]))
        #expect(item(.toggleEQShade)?.shortcut == MainMenuShortcut("e", [.command, .control]))
        #expect(item(.togglePlaylistShade)?.shortcut == MainMenuShortcut("p", [.command, .control]))
        let cc: MainMenuShortcut.Modifiers = [.command, .control]
        #expect(item(.toggleRepeat)?.shortcut == MainMenuShortcut("r", cc))
        #expect(item(.toggleShuffle)?.shortcut == MainMenuShortcut("s", cc))
        #expect(item(.previous)?.shortcut == MainMenuShortcut("z", cc))
        #expect(item(.play)?.shortcut == MainMenuShortcut("x", cc))
        #expect(item(.pause)?.shortcut == MainMenuShortcut("c", cc))
        #expect(item(.stop)?.shortcut == MainMenuShortcut("v", cc))
        #expect(item(.next)?.shortcut == MainMenuShortcut("b", cc))
        #expect(item(.jumpToFile)?.shortcut == MainMenuShortcut("j"))
        #expect(item(.nextSkin)?.shortcut == MainMenuShortcut("]"))
        #expect(item(.previousSkin)?.shortcut == MainMenuShortcut("["))
        #expect(item(.randomSkin)?.shortcut == MainMenuShortcut("r", [.command, .shift]))
        #expect(item(.toggleVisualization)?.shortcut == MainMenuShortcut("k", [.command, .shift]))
        #expect(item(.visualizationSettings)?.shortcut == MainMenuShortcut("k", [.command, .option]))
    }

    @Test func visualizationSubmenuHasSettings() {
        let entries = MainMenu.visualizationEntries(MainMenuState())
        #expect(entries.count == 2)
        let settings = item(.visualizationSettings)
        #expect(settings?.title == "Visualization Settings\u{2026}")
        #expect(settings?.shortcut == MainMenuShortcut("k", [.command, .option]))
    }

    @Test func visualizationSubmenuHasStartStop() {
        let entries = MainMenu.entries(MainMenuState())
        let titles = entries.compactMap { entry -> String? in
            if case .submenu(let title, _) = entry { return title }
            return nil
        }
        #expect(titles.contains("Visualization"))
        let closed = item(.toggleVisualization)
        #expect(closed?.title == "Start/Stop Visualization")
        #expect(closed?.shortcut == MainMenuShortcut("k", [.command, .shift]))
        #expect(closed?.state == .off)
        #expect(item(.toggleVisualization, MainMenuState(isVisualizationOpen: true))?.state == .on)
    }

    @Test func jumpToFileClosesThePlaybackSubmenu() {
        let labels = MainMenu.playbackEntries(MainMenuState()).map { entry -> String in
            switch entry {
            case .item(let item): item.title
            case .separator: "-"
            default: "?"
            }
        }
        #expect(labels == ["Previous", "Play", "Pause", "Stop", "Next", "-", "Jump to File\u{2026}"])
    }

    @Test func shortcutsAreUnique() {
        let keys = items(MainMenu.entries(MainMenuState())).compactMap(\.shortcut).map { "\($0.key)|\($0.modifiers.rawValue)" }
        #expect(!keys.isEmpty)
        #expect(Set(keys).count == keys.count)
    }
}
