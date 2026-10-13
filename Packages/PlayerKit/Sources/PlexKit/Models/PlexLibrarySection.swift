import Foundation

public struct PlexLibrarySection: Codable, Hashable, Sendable, Identifiable {
    /// Plex sends `"key": "5"` as a string.
    public var key: String
    public var title: String
    /// "artist" | "movie" | "show" | ...
    public var type: String
    public var uuid: String?

    public var id: String { key }
    public var isMusic: Bool { type == "artist" }

    public init(key: String, title: String, type: String, uuid: String? = nil) {
        self.key = key
        self.title = title
        self.type = type
        self.uuid = uuid
    }
}
