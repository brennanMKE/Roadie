import Foundation

/// Plex wraps every JSON answer in `{"MediaContainer": {...}}`.
struct MediaContainerEnvelope<Item: Decodable>: Decodable {
    var container: Body

    struct Body: Decodable {
        var size: Int?
        var offset: Int?
        var totalSize: Int?
        var metadata: [Item]?
        var directory: [Item]?

        enum CodingKeys: String, CodingKey {
            case size, offset, totalSize
            case metadata = "Metadata"
            case directory = "Directory"
        }
    }

    enum CodingKeys: String, CodingKey {
        case container = "MediaContainer"
    }
}

/// `/identity` carries its fields directly in the container.
struct IdentityEnvelope: Decodable {
    var container: PlexIdentity

    enum CodingKeys: String, CodingKey {
        case container = "MediaContainer"
    }
}
