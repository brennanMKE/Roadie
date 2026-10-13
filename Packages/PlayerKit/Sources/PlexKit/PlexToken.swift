import Foundation

/// A Plex auth token. Prints as `PlexToken(redacted)` and is deliberately not `Codable`,
/// so it cannot ride along in a JSON index or a settings file.
public struct PlexToken: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The Keychain store reads this; nothing else should.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { "PlexToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
