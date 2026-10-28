/// The playlist editor's commands (the ADD, REM, SEL, MISC and LIST buttons), as plain data (#0226). The skinned
/// pop-ups, the menu bar's Playlist menu and the SORT / MISC OPTIONS pop-ups read titles, enabled state and shortcuts
/// from here, so they can't drift.
public enum PlaylistCommand: Hashable, Sendable, CaseIterable {
    case addFile, addFolder, addURL
    case removeSelected, crop, clearPlaylist
    case selectAll, selectNone, invertSelection
    case sortByTitle, sortByFileName, sortByPath, reverse, randomize, fileInfo, generateHTML
    case loadPlaylist, savePlaylist
}

/// What the commands' enabled states follow.
public struct PlaylistMenuState: Equatable, Sendable {
    public var hasRows: Bool
    public var hasSelection: Bool
    /// The rows are a Music Assistant queue, which can't be sorted (#0145).
    public var isRemote: Bool
    /// The Library has a Radio section (#0147).
    public var canAddURL: Bool
    /// A selected row or a current track.
    public var hasFileInfo: Bool
    public var canSave: Bool
    public var canLoad: Bool

    public init(
        hasRows: Bool = false, hasSelection: Bool = false, isRemote: Bool = false, canAddURL: Bool = false,
        hasFileInfo: Bool = false, canSave: Bool = false, canLoad: Bool = false
    ) {
        self.hasRows = hasRows
        self.hasSelection = hasSelection
        self.isRemote = isRemote
        self.canAddURL = canAddURL
        self.hasFileInfo = hasFileInfo
        self.canSave = canSave
        self.canLoad = canLoad
    }
}

public struct PlaylistMenuItem: Equatable, Sendable {
    public var command: PlaylistCommand
    public var title: String
    public var isEnabled: Bool
    public var shortcut: MainMenuShortcut?

    public init(_ command: PlaylistCommand, _ title: String, isEnabled: Bool, shortcut: MainMenuShortcut? = nil) {
        self.command = command
        self.title = title
        self.isEnabled = isEnabled
        self.shortcut = shortcut
    }
}

public enum PlaylistMenuEntry: Equatable, Sendable {
    case item(PlaylistMenuItem)
    case separator
}

public enum PlaylistMenu {
    /// The one place titles, enabled rules and shortcuts live. Disabled only where the command would do nothing and
    /// say nothing; Add File… and Add Folder… stay enabled (a speaker's refusal is a notice, #0084).
    public static func item(_ command: PlaylistCommand, _ state: PlaylistMenuState) -> PlaylistMenuItem {
        let sortable = state.hasRows && !state.isRemote
        let alt: MainMenuShortcut.Modifiers = [.command, .option]
        switch command {
        case .addFile: return PlaylistMenuItem(command, "Add File\u{2026}", isEnabled: true)
        case .addFolder: return PlaylistMenuItem(command, "Add Folder\u{2026}", isEnabled: true)
        case .addURL: return PlaylistMenuItem(command, "Add URL\u{2026}", isEnabled: state.canAddURL)
        case .removeSelected: return PlaylistMenuItem(command, "Remove Selected", isEnabled: state.hasSelection)
        case .crop: return PlaylistMenuItem(command, "Crop", isEnabled: state.hasSelection)
        case .clearPlaylist: return PlaylistMenuItem(command, "Clear Playlist", isEnabled: state.hasRows)
        case .selectAll: return PlaylistMenuItem(command, "Select All", isEnabled: state.hasRows)
        case .selectNone: return PlaylistMenuItem(command, "Select None", isEnabled: state.hasRows)
        case .invertSelection: return PlaylistMenuItem(command, "Invert Selection", isEnabled: state.hasRows)
        case .sortByTitle:
            return PlaylistMenuItem(command, "Sort by Title", isEnabled: sortable, shortcut: MainMenuShortcut("1", alt))
        case .sortByFileName:
            return PlaylistMenuItem(command, "Sort by File Name", isEnabled: sortable, shortcut: MainMenuShortcut("2", alt))
        case .sortByPath:
            return PlaylistMenuItem(
                command, "Sort by Path and File Name", isEnabled: sortable, shortcut: MainMenuShortcut("3", alt))
        case .reverse: return PlaylistMenuItem(command, "Reverse List", isEnabled: sortable)
        case .randomize: return PlaylistMenuItem(command, "Randomize List", isEnabled: sortable)
        case .fileInfo: return PlaylistMenuItem(command, "File Info\u{2026}", isEnabled: state.hasFileInfo)
        case .generateHTML: return PlaylistMenuItem(command, "Generate HTML Playlist", isEnabled: state.hasRows)
        case .loadPlaylist:
            return PlaylistMenuItem(command, "Load Playlist\u{2026}", isEnabled: state.canLoad, shortcut: MainMenuShortcut("l", alt))
        case .savePlaylist:
            return PlaylistMenuItem(command, "Save Playlist\u{2026}", isEnabled: state.canSave, shortcut: MainMenuShortcut("s", alt))
        }
    }

    /// The groups of the five buttons, in order: Add, Remove, Select, Misc, List.
    public static let groups: [[PlaylistCommand]] = [
        [.addFile, .addFolder, .addURL],
        [.removeSelected, .crop, .clearPlaylist],
        [.selectAll, .selectNone, .invertSelection],
        [.sortByTitle, .sortByFileName, .sortByPath, .reverse, .randomize, .fileInfo, .generateHTML],
        [.loadPlaylist, .savePlaylist],
    ]

    /// The menu bar's Playlist menu.
    public static func menuBarEntries(_ state: PlaylistMenuState) -> [PlaylistMenuEntry] {
        var entries: [PlaylistMenuEntry] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { entries.append(.separator) }
            entries += group.map { .item(item($0, state)) }
        }
        return entries
    }

    /// What MISC › SORT LIST pops up.
    public static func sortEntries(_ state: PlaylistMenuState) -> [PlaylistMenuEntry] {
        [
            .item(item(.sortByTitle, state)), .item(item(.sortByFileName, state)), .item(item(.sortByPath, state)),
            .separator,
            .item(item(.reverse, state)), .item(item(.randomize, state)),
        ]
    }

    /// What the track list's right-click menu adds, on a row and below the rows (#0229).
    public static func contextEntries(_ state: PlaylistMenuState) -> [PlaylistMenuEntry] {
        [.item(item(.loadPlaylist, state)), .item(item(.clearPlaylist, state))]
    }

    /// What MISC › MISC OPTIONS pops up.
    public static func miscOptionsEntries(_ state: PlaylistMenuState) -> [PlaylistMenuEntry] {
        [.item(item(.generateHTML, state))]
    }

    /// The command a skinned entry runs. SORT LIST and MISC OPTIONS pop up menus, and REMOVE MISC does nothing: nil.
    public static func command(forSprite sprite: String) -> PlaylistCommand? {
        switch sprite {
        case "PLAYLIST_ADD_FILE": .addFile
        case "PLAYLIST_ADD_DIR": .addFolder
        case "PLAYLIST_ADD_URL": .addURL
        case "PLAYLIST_REMOVE_SELECTED": .removeSelected
        case "PLAYLIST_CROP": .crop
        case "PLAYLIST_REMOVE_ALL", "PLAYLIST_NEW_LIST": .clearPlaylist
        case "PLAYLIST_SELECT_ALL": .selectAll
        case "PLAYLIST_SELECT_ZERO": .selectNone
        case "PLAYLIST_INVERT_SELECTION": .invertSelection
        case "PLAYLIST_FILE_INFO": .fileInfo
        case "PLAYLIST_LOAD_LIST": .loadPlaylist
        case "PLAYLIST_SAVE_LIST": .savePlaylist
        default: nil
        }
    }
}
