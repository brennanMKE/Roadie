import Foundation

public struct PlexTrack: Codable, Hashable, Sendable, Identifiable {
    public var ratingKey: String
    /// "/library/metadata/<ratingKey>" (tracks have no `/children`).
    public var key: String
    public var title: String
    /// The album's rating key.
    public var parentRatingKey: String?
    /// The artist's rating key.
    public var grandparentRatingKey: String?
    public var parentTitle: String?
    public var grandparentTitle: String?
    /// Track number.
    public var index: Int?
    /// Disc number.
    public var parentIndex: Int?
    /// Milliseconds.
    public var duration: Int?
    public var thumb: String?
    public var parentThumb: String?
    public var grandparentThumb: String?
    public var addedAt: Int?
    public var updatedAt: Int?
    public var media: [PlexMedia]

    public var id: String { ratingKey }
    public var durationSeconds: TimeInterval? { duration.map { Double($0) / 1000 } }
    public var primaryPart: PlexPart? { media.first?.parts.first }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, title, parentRatingKey, grandparentRatingKey, parentTitle, grandparentTitle
        case index, parentIndex, duration, thumb, parentThumb, grandparentThumb, addedAt, updatedAt
        case media = "Media"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = try c.decode(String.self, forKey: .ratingKey)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        parentRatingKey = try c.decodeIfPresent(String.self, forKey: .parentRatingKey)
        grandparentRatingKey = try c.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        parentTitle = try c.decodeIfPresent(String.self, forKey: .parentTitle)
        grandparentTitle = try c.decodeIfPresent(String.self, forKey: .grandparentTitle)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try c.decodeIfPresent(Int.self, forKey: .parentIndex)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        parentThumb = try c.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentThumb = try c.decodeIfPresent(String.self, forKey: .grandparentThumb)
        addedAt = try c.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt)
        media = try c.decodeIfPresent([PlexMedia].self, forKey: .media) ?? []
    }
}

public struct PlexMedia: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var duration: Int?
    /// kbps.
    public var bitrate: Int?
    public var audioChannels: Int?
    /// "mp3", "aac", ...
    public var audioCodec: String?
    /// "mp3", "mp4", ...
    public var container: String?
    public var parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, audioChannels, audioCodec, container
        case parts = "Part"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        audioChannels = try c.decodeIfPresent(Int.self, forKey: .audioChannels)
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        parts = try c.decodeIfPresent([PlexPart].self, forKey: .parts) ?? []
    }
}

public struct PlexPart: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    /// "/library/parts/<id>/<stamp>/file.mp3"
    public var key: String
    public var duration: Int?
    /// Bytes. A download can be checked against it.
    public var size: Int?
    public var container: String?
    // `file` (the server's filesystem path) is deliberately not decoded.

    /// The numeric path component after the part id in `key` (Plex's change stamp).
    public var keyStamp: Int? {
        let parts = key.split(separator: "/")
        guard parts.count >= 4, parts[0] == "library", parts[1] == "parts" else { return nil }
        return Int(parts[3])
    }

    /// "mp3", "m4a", ...
    public var fileExtension: String { (key as NSString).pathExtension }
}
