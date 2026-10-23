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
                "About Roadie", "-", "Play File…", "Add to Playlist…", "-", "Equalizer", "Playlist Editor", "-",
                "Skins >", "Options >", "Playback >", "-", "Exit",
            ])
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
        #expect(commands.count == 24)
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
        #expect(item(.nextSkin)?.shortcut == MainMenuShortcut("]"))
        #expect(item(.previousSkin)?.shortcut == MainMenuShortcut("["))
        #expect(item(.randomSkin)?.shortcut == MainMenuShortcut("r", [.command, .shift]))
    }

    @Test func shortcutsAreUnique() {
        let keys = items(MainMenu.entries(MainMenuState())).compactMap(\.shortcut).map { "\($0.key)|\($0.modifiers.rawValue)" }
        #expect(!keys.isEmpty)
        #expect(Set(keys).count == keys.count)
    }
}
