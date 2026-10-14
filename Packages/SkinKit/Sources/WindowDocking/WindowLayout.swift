import CoreGraphics
import Foundation

/// Where each skinned window sits, in desktop space (top-left origin, y down, points). Whether a window is open or
/// shaded, and the playlist's size, are persisted by the player model; the layout holds positions only.
public struct WindowLayout: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var left: CGFloat
        public var top: CGFloat

        public init(left: CGFloat, top: CGFloat) {
            self.left = left
            self.top = top
        }
    }

    public static let currentVersion = 1

    public var version = WindowLayout.currentVersion
    public var windows: [WindowKind: Entry]

    public init(windows: [WindowKind: Entry] = [:]) {
        self.windows = windows
    }
}

extension WindowLayout: Codable {
    private enum CodingKeys: String, CodingKey { case version, windows }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // Decode by name and drop kinds this build does not know, so a later window kind does not brick older builds.
        let raw = try container.decode([String: Entry].self, forKey: .windows)
        windows = raw.reduce(into: [:]) { result, pair in
            if let kind = WindowKind(rawValue: pair.key) { result[kind] = pair.value }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(Dictionary(uniqueKeysWithValues: windows.map { ($0.key.rawValue, $0.value) }), forKey: .windows)
    }
}

/// The layout as one JSON value under one `UserDefaults` key.
public struct WindowLayoutStore {
    public static let defaultKey = "windowLayout"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = WindowLayoutStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// nil when nothing is stored, the value is corrupt, or it is from a newer version.
    public func load() -> WindowLayout? {
        guard let data = defaults.data(forKey: key),
            let layout = try? JSONDecoder().decode(WindowLayout.self, from: data),
            layout.version == WindowLayout.currentVersion
        else { return nil }
        return layout
    }

    public func save(_ layout: WindowLayout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(layout) else { return }
        defaults.set(data, forKey: key)
    }
}
