import AppKit
import SwiftUI

/// Maps `pledit.txt`'s Windows font name to a font that exists here. Windows-only names (`Tempus Sans ITC`,
/// `MS Sans Serif`) go to Arial, which ships with macOS; the system font is the last resort.
@MainActor
enum PlaylistFont {
    private static var cache: [String: NSFont] = [:]

    static func nsFont(for name: String) -> NSFont {
        if let cached = cache[name] { return cached }
        let font = NSFont(name: name, size: 9) ?? NSFont(name: "Arial", size: 9) ?? .systemFont(ofSize: 9)
        cache[name] = font
        return font
    }

    static func font(for name: String) -> Font { Font(nsFont(for: name)) }
}
