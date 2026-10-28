import Testing
@testable import SkinKit

/// The playlist editor's commands as plain data (#0226).
struct PlaylistMenuTests {
    private let full = PlaylistMenuState(
        hasRows: true, hasSelection: true, isRemote: false, canAddURL: true, hasFileInfo: true, canSave: true, canLoad: true)

    private func items(_ entries: [PlaylistMenuEntry]) -> [PlaylistMenuItem] {
        entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    private func enabled(_ state: PlaylistMenuState) -> Set<PlaylistCommand> {
        Set(items(PlaylistMenu.menuBarEntries(state)).filter(\.isEnabled).map(\.command))
    }

    private func key(_ shortcut: MainMenuShortcut) -> String { "\(shortcut.modifiers.rawValue)-\(shortcut.key)" }

    @Test func menuBarHasEveryCommandOnce() {
        let entries = PlaylistMenu.menuBarEntries(full)
        let commands = items(entries).map(\.command)
        #expect(commands.count == PlaylistCommand.allCases.count)
        #expect(Set(commands) == Set(PlaylistCommand.allCases))
        #expect(commands == PlaylistMenu.groups.flatMap { $0 })
        // Groups: Add, Remove, Select, Misc, List, with a separator between each.
        let groups = entries.split(separator: .separator).map { items(Array($0)).map(\.command) }
        #expect(groups.count == 5)
        #expect(groups.first == [.addFile, .addFolder, .addURL])
        #expect(groups.last == [.loadPlaylist, .savePlaylist])
        #expect(items(entries).map(\.title) == [
            "Add File…", "Add Folder…", "Add URL…", "Remove Selected", "Crop", "Clear Playlist", "Select All",
            "Select None", "Invert Selection", "Sort by Title", "Sort by File Name", "Sort by Path and File Name",
            "Reverse List", "Randomize List", "File Info…", "Generate HTML Playlist", "Load Playlist…", "Save Playlist…",
        ])
    }

    @Test func everySkinnedEntryMapsToACommand() {
        let layout = PlaylistLayout(steps: .init(width: 0, height: 0))
        let unmapped: Set<String> = ["PLAYLIST_SORT_LIST", "PLAYLIST_MISC_OPTIONS", "PLAYLIST_REMOVE_MISC"]
        var mapped: Set<PlaylistCommand> = []
        for menu in PlaylistLayout.Menu.allCases {
            for entry in layout.menuEntries(menu) {
                let command = PlaylistMenu.command(forSprite: entry.sprite)
                if unmapped.contains(entry.sprite) {
                    #expect(command == nil, "\(entry.sprite)")
                } else {
                    #expect(command != nil, "\(entry.sprite) has no command")
                    if let command { mapped.insert(command) }
                }
            }
        }
        #expect(PlaylistMenu.command(forSprite: "PLAYLIST_NEW_LIST") == .clearPlaylist)
        #expect(PlaylistMenu.command(forSprite: "PLAYLIST_REMOVE_ALL") == .clearPlaylist)
        // What the skin reaches directly, plus the SORT and MISC OPTIONS pop-ups, is every command.
        let popUps = items(PlaylistMenu.sortEntries(full) + PlaylistMenu.miscOptionsEntries(full)).map(\.command)
        #expect(mapped.union(popUps) == Set(PlaylistCommand.allCases))
    }

    @Test func enabledFollowsTheState() {
        #expect(enabled(PlaylistMenuState()) == [.addFile, .addFolder])
        #expect(enabled(PlaylistMenuState(canAddURL: true, canLoad: true)) == [.addFile, .addFolder, .addURL, .loadPlaylist])

        let rows = PlaylistMenuState(hasRows: true)
        #expect(!enabled(rows).contains(.removeSelected))
        #expect(!enabled(rows).contains(.crop))
        #expect(enabled(rows).isSuperset(of: [.clearPlaylist, .selectAll, .selectNone, .invertSelection, .sortByTitle, .reverse]))
        let selected = PlaylistMenuState(hasRows: true, hasSelection: true)
        #expect(enabled(selected).isSuperset(of: [.removeSelected, .crop]))

        var remote = full
        remote.isRemote = true
        let sorts: Set<PlaylistCommand> = [.sortByTitle, .sortByFileName, .sortByPath, .reverse, .randomize]
        #expect(enabled(remote).isDisjoint(with: sorts))
        #expect(enabled(full).isSuperset(of: sorts))

        #expect(enabled(full) == Set(PlaylistCommand.allCases))
        for (path, command) in [(\PlaylistMenuState.canSave, PlaylistCommand.savePlaylist), (\.canLoad, .loadPlaylist),
                                (\.hasFileInfo, .fileInfo), (\.canAddURL, .addURL)] {
            var state = full
            state[keyPath: path] = false
            #expect(!enabled(state).contains(command), "\(command)")
        }
    }

    @Test func shortcutsAreUnique() {
        let shortcuts = items(PlaylistMenu.menuBarEntries(full)).compactMap(\.shortcut).map(key)
        #expect(Set(shortcuts).count == shortcuts.count)
        // The orchestrator's decision (#0226 Fix): sorts, Load and Save only.
        let withShortcut = items(PlaylistMenu.menuBarEntries(full)).filter { $0.shortcut != nil }.map(\.command)
        #expect(withShortcut == [.sortByTitle, .sortByFileName, .sortByPath, .loadPlaylist, .savePlaylist])
    }

    @Test func shortcutsDontCollideWithTheMenuBar() {
        func mainItems(_ entries: [MainMenuEntry]) -> [MainMenuItem] {
            entries.flatMap { entry -> [MainMenuItem] in
                switch entry {
                case .item(let item): [item]
                case .separator: []
                case .submenu(_, let children): mainItems(children)
                }
            }
        }
        var taken = Set(mainItems(MainMenu.entries(MainMenuState())).compactMap(\.shortcut).map(key))
        let control: MainMenuShortcut.Modifiers = [.command, .control]
        let others: [MainMenuShortcut] = [
            MainMenuShortcut("k"), MainMenuShortcut("s"), MainMenuShortcut("l"), MainMenuShortcut("j"), MainMenuShortcut("a"),
            MainMenuShortcut("n"), MainMenuShortcut("\u{8}"), MainMenuShortcut("o"), MainMenuShortcut("1"),
            MainMenuShortcut("l", control), MainMenuShortcut("s", control), MainMenuShortcut("r", control),
            MainMenuShortcut("3", [.command, .shift]), MainMenuShortcut("4", [.command, .shift]),
            MainMenuShortcut("5", [.command, .shift]),
        ]
        taken.formUnion(others.map(key))
        let ours = items(PlaylistMenu.menuBarEntries(full)).compactMap(\.shortcut).map(key)
        #expect(taken.isDisjoint(with: ours))
    }

    @Test func sortAndMiscPopUpsUseTheSameTitles() {
        let bar = Dictionary(uniqueKeysWithValues: items(PlaylistMenu.menuBarEntries(full)).map { ($0.command, $0.title) })
        for item in items(PlaylistMenu.sortEntries(full) + PlaylistMenu.miscOptionsEntries(full)) {
            #expect(item.title == bar[item.command])
        }
        #expect(items(PlaylistMenu.sortEntries(full)).map(\.title) == [
            "Sort by Title", "Sort by File Name", "Sort by Path and File Name", "Reverse List", "Randomize List",
        ])
    }
}
