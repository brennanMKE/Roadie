import Foundation

public struct PlexArtist: Codable, Hashable, Sendable, Identifiable {
    public var ratingKey: String
    /// "/library/metadata/<ratingKey>/children"
    public var key: String
    public var title: String
    public var titleSort: String?
    public var summary: String?
    public var thumb: String?
    public var addedAt: Int?
    public var updatedAt: Int?

    public var id: String { ratingKey }
}
