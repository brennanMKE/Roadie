import Foundation

/// A Winamp transport hotkey, pressed bare while a skinned window is key.
public enum WinampHotkey: Sendable, CaseIterable {
    case previous, play, pause, stop, next
    case seekBack, seekForward, volumeUp, volumeDown
    case toggleShuffle, toggleRepeat, openFile, jumpToFile
}

/// Winamp's bare-key bindings (Z X C V B, arrows, S R L J) and the seek and volume steps they apply.
public enum WinampHotkeys {
    public static let seekStep: TimeInterval = 5
    /// Webamp's `adjustVolume(±1)` on its 0–100 scale.
    public static let volumeStep: Float = 0.01

    // AppKit function-key characters.
    static let upArrow = "\u{F700}"
    static let downArrow = "\u{F701}"
    static let leftArrow = "\u{F702}"
    static let rightArrow = "\u{F703}"

    /// The hotkey for a key press, or nil when it carries ⌘ ⌃ ⌥ or ⇧, is unmapped, or is a repeated letter.
    /// Caps Lock is ignored by lowercasing; only the arrows repeat while held.
    public static func hotkey(
        charactersIgnoringModifiers characters: String,
        command: Bool, control: Bool, option: Bool, shift: Bool, isRepeat: Bool
    ) -> WinampHotkey? {
        guard !command, !control, !option, !shift else { return nil }
        switch characters {
        case leftArrow: return .seekBack
        case rightArrow: return .seekForward
        case upArrow: return .volumeUp
        case downArrow: return .volumeDown
        default: break
        }
        guard !isRepeat else { return nil }
        switch characters.lowercased() {
        case "z": return .previous
        case "x": return .play
        case "c": return .pause
        case "v": return .stop
        case "b": return .next
        case "s": return .toggleShuffle
        case "r": return .toggleRepeat
        case "l": return .openFile
        case "j": return .jumpToFile
        default: return nil
        }
    }

    /// `elapsed` moved by `seekStep`, clamped to the track; nil when the length is unknown.
    public static func seekTarget(elapsed: TimeInterval, duration: TimeInterval, forward: Bool) -> TimeInterval? {
        guard duration > 0 else { return nil }
        let target = elapsed + (forward ? seekStep : -seekStep)
        return min(max(target, 0), duration)
    }

    /// `volume` moved by `volumeStep`, clamped to 0...1.
    public static func nudgedVolume(_ volume: Float, up: Bool) -> Float {
        min(max(volume + (up ? volumeStep : -volumeStep), 0), 1)
    }
}
