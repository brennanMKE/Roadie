import Foundation

/// Music Assistant's row icons (Material Design Icons names) as SF Symbols (#0143).
public enum MDIIcon {
    public static let fallback = "sparkles"

    static let table: [String: String] = [
        "mdi-motion-play": "play.circle",
        "mdi-play-circle": "play.circle",
        "mdi-album": "square.stack",
        "mdi-music-note-plus": "plus.square",
        "mdi-timer-sand": "hourglass",
        "mdi-trophy": "trophy",
        "mdi-sleep": "moon.zzz",
        "mdi-podcast": "antenna.radiowaves.left.and.right",
        "mdi-radio": "antenna.radiowaves.left.and.right",
        "mdi-history": "clock.arrow.circlepath",
        "mdi-heart": "heart",
        "mdi-shuffle": "shuffle",
        "mdi-shuffle-variant": "shuffle",
        "mdi-account-music": "music.mic",
        "mdi-playlist-music": "music.note.list",
        "mdi-music-note": "music.note",
    ]

    /// The symbol for an mdi name (with or without the `mdi-` prefix); `fallback` for nil or an unknown name.
    public static func symbol(_ name: String?) -> String {
        guard var name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return fallback }
        if !name.hasPrefix("mdi-") { name = "mdi-" + name }
        return table[name] ?? fallback
    }
}
