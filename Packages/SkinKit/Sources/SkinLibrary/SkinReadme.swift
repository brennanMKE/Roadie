import Foundation
import SkinKit

/// Picks a readme out of a skin archive's text entries.
public enum SkinReadme {
    static let ignored: Set<String> = ["pledit.txt", "viscolor.txt", "region.txt", "winampmb.txt", "pledit_example.txt", "mb.ini"]
    static let maxLength = 64 * 1024

    public static func extract(from archive: SkinArchive) -> String? {
        let candidates = archive.files.filter { name, _ in
            (name.hasSuffix(".txt") || name.hasSuffix(".nfo")) && !ignored.contains(name)
        }
        guard !candidates.isEmpty else { return nil }
        for marker in ["readme", "read me", "read_me"] {
            let matches = candidates.filter { $0.key.contains(marker) }
            if let best = matches.min(by: { $0.key < $1.key }) { return normalize(decode(best.value)) }
        }
        // Largest, ties broken by name so the choice is deterministic.
        let best = candidates.min { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key
        }
        return best.map { normalize(decode($0.value)) }
    }

    /// UTF-8 when valid, otherwise Windows-1252 (which cannot fail for the bytes it defines).
    public static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func normalize(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\0", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength)) }
        return cleaned
    }
}
