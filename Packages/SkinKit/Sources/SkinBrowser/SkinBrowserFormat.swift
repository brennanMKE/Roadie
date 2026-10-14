import Foundation

/// Pure labels and path helpers for the Skins window.
public enum SkinBrowserFormat {
    private static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "1,234 of 98,765 skins", "98,765 skins", "No skins"; empty until the counts arrive.
    public static func countLabel(matching: Int?, total: Int?, isFiltered: Bool) -> String {
        if total == 0 || matching == 0 { return "No skins" }
        if isFiltered, let matching, let total { return "\(number(matching)) of \(number(total)) skins" }
        guard let shown = isFiltered ? nil : (total ?? matching) else { return "" }
        return "\(number(shown)) skins"
    }

    /// "12 ms" (rounded), nil when nothing was measured.
    public static func elapsedLabel(_ duration: Duration?) -> String? {
        guard let duration else { return nil }
        let parts = duration.components
        let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        return "\(Int(milliseconds.rounded())) ms"
    }

    public static func fileURL(folder: URL, path: String) -> URL {
        folder.appending(path: path, directoryHint: .notDirectory)
    }

    /// `url` relative to `folder` ("a/b.wsz"), nil when it is outside it. Both sides are standardized and
    /// symlink-resolved, the same root rule as `FolderScanner`.
    public static func relativePath(of url: URL, in folder: URL) -> String? {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        return parts.dropFirst(root.count).joined(separator: "/")
    }
}
