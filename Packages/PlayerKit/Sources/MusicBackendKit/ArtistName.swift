import Foundation

/// Pure functions over artist names. `key` decides which spellings are the same artist; `display` is what the UI shows.
public enum ArtistName {
    /// Shown when a name is empty after cleaning.
    public static let unknown = "Unknown Artist"

    /// The name as written, minus trailing `;` and stray whitespace, with runs of whitespace collapsed.
    /// `unknown` when nothing is left. Idempotent.
    public static func display(_ name: String) -> String {
        let cleaned = clean(name)
        return cleaned.isEmpty ? unknown : cleaned
    }

    /// The grouping key: case-folded, `and` equal to `&`, trailing `;` dropped, whitespace collapsed.
    /// Empty for a name with nothing in it. Idempotent.
    public static func key(_ name: String) -> String {
        let cleaned = clean(name)
        guard !cleaned.isEmpty else { return "" }
        let spaced = cleaned.replacingOccurrences(of: "&", with: " & ")
        let tokens = words(spaced).map { $0.caseInsensitiveCompare("and") == .orderedSame ? "&" : $0 }
        return tokens.joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private static func clean(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return words(text).joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}
