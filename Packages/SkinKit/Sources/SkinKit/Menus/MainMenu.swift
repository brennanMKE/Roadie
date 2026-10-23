/// The main window's options menu (Winamp's main menu, Webamp `MainContextMenu`), as plain data. The app builds the
/// `NSMenu` from these entries in one place; features Roadie does not have yet are left out rather than disabled.
public enum MainMenuCommand: Hashable, Sendable {
    case about, checkForUpdates, openFiles, addFiles, toggleEQWindow, togglePlaylistWindow
    case openSkin, nextSkin, previousSkin, randomSkin
    case timeElapsed, timeRemaining, toggleAlwaysOnTop, toggleDoubleSize, toggleMainShade, toggleEQShade, togglePlaylistShade, toggleRepeat, toggleShuffle
    case previous, play, pause, stop, next
    case quit
}

/// What the menu's checks and enabled states follow.
public struct MainMenuState: Equatable, Sendable {
    public var timeMode: TimeMode
    public var isEQWindowOpen: Bool
    public var isPlaylistWindowOpen: Bool
    public var isMainShaded: Bool
    public var isEQShaded: Bool
    public var isPlaylistShaded: Bool
    public var isRepeating: Bool
    public var isShuffled: Bool
    public var canNavigateSkins: Bool
    public var isAlwaysOnTop: Bool
    public var isDoubleSize: Bool
    /// Sparkle's updater can check now (#0158); false in Debug builds, where it never starts.
    public var canCheckForUpdates: Bool

    public init(
        timeMode: TimeMode = .elapsed, isEQWindowOpen: Bool = false, isPlaylistWindowOpen: Bool = false,
        isMainShaded: Bool = false, isEQShaded: Bool = false, isPlaylistShaded: Bool = false,
        isRepeating: Bool = false, isShuffled: Bool = false, canNavigateSkins: Bool = false,
        isAlwaysOnTop: Bool = false, isDoubleSize: Bool = false, canCheckForUpdates: Bool = false
    ) {
        self.timeMode = timeMode
        self.isEQWindowOpen = isEQWindowOpen
        self.isPlaylistWindowOpen = isPlaylistWindowOpen
        self.isMainShaded = isMainShaded
        self.isEQShaded = isEQShaded
        self.isPlaylistShaded = isPlaylistShaded
        self.isRepeating = isRepeating
        self.isShuffled = isShuffled
        self.canNavigateSkins = canNavigateSkins
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isDoubleSize = isDoubleSize
        self.canCheckForUpdates = canCheckForUpdates
    }
}

/// A key equivalent shown beside an item. In a popped-up menu it is display only; it must match the menu bar's.
public struct MainMenuShortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct MainMenuItem: Equatable, Sendable {
    public enum CheckState: Equatable, Sendable { case off, on }

    public var command: MainMenuCommand
    public var title: String
    public var state: CheckState
    public var isEnabled: Bool
    public var shortcut: MainMenuShortcut?

    public init(
        _ command: MainMenuCommand, _ title: String, checked: Bool = false, isEnabled: Bool = true,
        shortcut: MainMenuShortcut? = nil
    ) {
        self.command = command
        self.title = title
        self.state = checked ? .on : .off
        self.isEnabled = isEnabled
        self.shortcut = shortcut
    }
}

public indirect enum MainMenuEntry: Equatable, Sendable {
    case item(MainMenuItem)
    case separator
    case submenu(title: String, [MainMenuEntry])
}

public enum MainMenu {
    public static func entries(_ state: MainMenuState) -> [MainMenuEntry] {
        [
            .item(MainMenuItem(.about, "About Roadie")),
            .item(MainMenuItem(.checkForUpdates, "Check for Updates…", isEnabled: state.canCheckForUpdates)),
            .separator,
            .item(MainMenuItem(.openFiles, "Play File…", shortcut: MainMenuShortcut("o"))),
            .item(MainMenuItem(.addFiles, "Add to Playlist…", shortcut: MainMenuShortcut("o", [.command, .option]))),
            .separator,
            .item(MainMenuItem(.toggleEQWindow, "Equalizer", checked: state.isEQWindowOpen, shortcut: MainMenuShortcut("2"))),
            .item(
                MainMenuItem(
                    .togglePlaylistWindow, "Playlist Editor", checked: state.isPlaylistWindowOpen,
                    shortcut: MainMenuShortcut("3"))),
            .separator,
            .submenu(title: "Skins", skinsEntries(state)),
            .submenu(title: "Options", optionsEntries(state)),
            .submenu(title: "Playback", playbackEntries(state)),
            .separator,
            .item(MainMenuItem(.quit, "Exit", shortcut: MainMenuShortcut("q"))),
        ]
    }

    public static func skinsEntries(_ state: MainMenuState) -> [MainMenuEntry] {
        let nav = state.canNavigateSkins
        return [
            .item(MainMenuItem(.openSkin, "Open Skin…", shortcut: MainMenuShortcut("o", [.command, .shift]))),
            .separator,
            .item(MainMenuItem(.nextSkin, "Next Skin", isEnabled: nav, shortcut: MainMenuShortcut("]"))),
            .item(MainMenuItem(.previousSkin, "Previous Skin", isEnabled: nav, shortcut: MainMenuShortcut("["))),
            .item(MainMenuItem(.randomSkin, "Random Skin", isEnabled: nav, shortcut: MainMenuShortcut("r", [.command, .shift]))),
        ]
    }

    public static func optionsEntries(_ state: MainMenuState) -> [MainMenuEntry] {
        [
            .item(MainMenuItem(.timeElapsed, "Time Elapsed", checked: state.timeMode == .elapsed)),
            .item(MainMenuItem(.timeRemaining, "Time Remaining", checked: state.timeMode == .remaining)),
            .item(MainMenuItem(.toggleAlwaysOnTop, "Always On Top", checked: state.isAlwaysOnTop)),
            .item(MainMenuItem(.toggleDoubleSize, "Double Size", checked: state.isDoubleSize)),
            .separator,
            .item(
                MainMenuItem(
                    .toggleMainShade, "Windowshade", checked: state.isMainShaded,
                    shortcut: MainMenuShortcut("w", [.command, .control]))),
            .item(
                MainMenuItem(
                    .toggleEQShade, "EQ Windowshade", checked: state.isEQShaded,
                    shortcut: MainMenuShortcut("e", [.command, .control]))),
            .item(
                MainMenuItem(
                    .togglePlaylistShade, "Playlist Windowshade", checked: state.isPlaylistShaded,
                    shortcut: MainMenuShortcut("p", [.command, .control]))),
            .separator,
            .item(MainMenuItem(.toggleRepeat, "Repeat", checked: state.isRepeating, shortcut: MainMenuShortcut("r", [.command, .control]))),
            .item(MainMenuItem(.toggleShuffle, "Shuffle", checked: state.isShuffled, shortcut: MainMenuShortcut("s", [.command, .control]))),
        ]
    }

    public static func playbackEntries(_ state: MainMenuState) -> [MainMenuEntry] {
        [
            .item(MainMenuItem(.previous, "Previous", shortcut: MainMenuShortcut("z", [.command, .control]))),
            .item(MainMenuItem(.play, "Play", shortcut: MainMenuShortcut("x", [.command, .control]))),
            .item(MainMenuItem(.pause, "Pause", shortcut: MainMenuShortcut("c", [.command, .control]))),
            .item(MainMenuItem(.stop, "Stop", shortcut: MainMenuShortcut("v", [.command, .control]))),
            .item(MainMenuItem(.next, "Next", shortcut: MainMenuShortcut("b", [.command, .control]))),
        ]
    }
}
