import Foundation

/// A key press without AppKit: the app maps `NSEvent` (`charactersIgnoringModifiers`, `specialKey`) to it.
public enum VisKey: Hashable, Sendable {
    case character(String), left, right, up, down, space, delete, escape, returnKey, function(Int)
}

public enum VisTransport: Sendable { case previous, play, pause, stop, next, volumeUp, volumeDown }

public enum VisReadout: String, CaseIterable, Sendable { case title, time, preset, fps }

public enum VisCommand: Hashable, Sendable {
    case nextPreset, previousPreset, hardCut, toggleOrder, toggleLock, presetList, showSongTitle, help
    case toggleReadout(VisReadout), toggleFullScreen, escape, transport(VisTransport)
}

/// The visualization window's keys (design §2.5).
public enum VisKeyMap {
    public static func command(
        for key: VisKey, command: Bool, control: Bool, option: Bool, shift: Bool, isRepeat: Bool
    ) -> VisCommand? {
        if command || control { return nil }
        if option {
            return key == .returnKey && !shift && !isRepeat ? .toggleFullScreen : nil
        }
        // ↑ ↓ repeat; nothing else does.
        switch key {
        case .up: return .transport(.volumeUp)
        case .down: return .transport(.volumeDown)
        default: break
        }
        if isRepeat { return nil }
        // `?` needs ⇧ on most layouts.
        if case .character("?") = key { return .help }
        if shift { return nil }
        switch key {
        case .right, .space: return .nextPreset
        case .left, .delete: return .previousPreset
        case .escape: return .escape
        case .returnKey, .up, .down: return nil
        case .function(let n):
            switch n {
            case 1: return .help
            case 2: return .toggleReadout(.title)
            case 3: return .toggleReadout(.time)
            case 4: return .toggleReadout(.preset)
            case 5: return .toggleReadout(.fps)
            default: return nil
            }
        case .character(let text):
            switch text.lowercased() {
            case "h": return .hardCut
            case "r": return .toggleOrder
            case "`": return .toggleLock
            case "l": return .presetList
            case "t": return .showSongTitle
            case "z": return .transport(.previous)
            case "x": return .transport(.play)
            case "c": return .transport(.pause)
            case "v": return .transport(.stop)
            case "b": return .transport(.next)
            default: return nil
            }
        }
    }

    /// One row per command for the help card and the right-click menu (#0236, #0239), in design §2.5's order.
    public static let rows: [(keys: String, title: String, command: VisCommand)] = [
        ("→ / Space", "Next Preset", .nextPreset),
        ("← / ⌫", "Previous Preset", .previousPreset),
        ("H", "Next Preset Without Blending", .hardCut),
        ("R", "Random Order", .toggleOrder),
        ("`", "Lock Preset", .toggleLock),
        ("L", "Presets…", .presetList),
        ("T", "Show Song Title", .showSongTitle),
        ("F2", "Song Title", .toggleReadout(.title)),
        ("F3", "Song Time", .toggleReadout(.time)),
        ("F4", "Preset Name", .toggleReadout(.preset)),
        ("F5", "Frame Rate", .toggleReadout(.fps)),
        ("F1 / ?", "Keyboard Shortcuts", .help),
        ("⌥↩", "Full Screen", .toggleFullScreen),
        ("Z", "Previous Track", .transport(.previous)),
        ("X", "Play", .transport(.play)),
        ("C", "Pause", .transport(.pause)),
        ("V", "Stop", .transport(.stop)),
        ("B", "Next Track", .transport(.next)),
        ("↑", "Volume Up", .transport(.volumeUp)),
        ("↓", "Volume Down", .transport(.volumeDown)),
    ]
}
