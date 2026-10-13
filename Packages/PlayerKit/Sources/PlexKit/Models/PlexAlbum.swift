import Foundation

public struct PlexAlbum: Codable, Hashable, Sendable, Identifiable {
    public var ratingKey: String
    public var key: String
    public var title: String
    /// The artist's rating key.
    public var parentRatingKey: String?
    /// The artist's name.
    public var parentTitle: String?
    public var index: Int?
    public var year: Int?
    public var originallyAvailableAt: String?
    /// Track count. The recorded server does not send it for album listings.
    public var leafCount: Int?
    /// Can be absent: the UI needs a placeholder.
    public var thumb: String?
    public var parentThumb: String?
    public var addedAt: Int?
    public var updatedAt: Int?

    public var id: String { ratingKey }
}
