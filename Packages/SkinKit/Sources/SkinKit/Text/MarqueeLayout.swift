import Foundation

/// Webamp's Marquee.tsx: the 154x6 strip at (111, 24) scrolls one 5 px character per step.
public enum MarqueeLayout {
    public static let width = 154
    /// CHAR_WIDTH
    public static let charWidth = 5
    /// MARQUEE_MAX_LENGTH
    public static let maxLength = 31
    /// SEPARATOR
    public static let separator = "  ***  "
    public static let stepInterval: Duration = .milliseconds(220)
    public static let resumeDelay: Duration = .seconds(1)

    /// Length in UTF-16 units of the NFC form, the same units `TextFont.cells(for:)` draws, so a decomposed
    /// file name ("e" + U+0301) is counted as the one cell it renders as.
    static func length(_ text: String) -> Int { text.precomposedStringWithCanonicalMapping.utf16.count }

    /// Text of 31 or more UTF-16 units scrolls; shorter text sits still.
    public static func isLong(_ text: String) -> Bool { length(text) >= maxLength }

    /// Long text twice with the separator between; short text padded with spaces to 31 units.
    public static func loopText(_ text: String) -> String {
        if isLong(text) { return text + separator + text }
        return text + String(repeating: " ", count: maxLength - length(text))
    }

    /// Pixels the loop is shifted left: short text 0; long text `mod(step * 5 + pixels, (count + 7) * 5)`
    /// with an always-positive modulus.
    public static func stepOffset(text: String, step: Int, pixels: Int) -> Int {
        guard isLong(text) else { return 0 }
        let period = (length(text) + separator.utf16.count) * charWidth
        return ((step * charWidth + pixels) % period + period) % period
    }
}
