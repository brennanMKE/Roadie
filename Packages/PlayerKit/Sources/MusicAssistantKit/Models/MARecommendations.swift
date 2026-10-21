import Foundation

/// `music/recommendations`: a row without its items (#0143). Unrecorded until #0133; shaped from
/// `music_assistant_models.media_items.RecommendationFolder` and decoded leniently: only `item_id` is required.
public struct MARecommendationFolder: Decodable, Hashable, Sendable {
    public var itemID: String
    public var provider: String
    public var name: String
    public var subtitle: String?
    /// An mdi icon name, e.g. `mdi-album`.
    public var icon: String?
    /// `default` or `timeline`.
    public var type: String?
    public var enabledByDefault: Bool
    public var supportsProviderFilter: Bool
    public var uri: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, subtitle, icon, type, uri
        case enabledByDefault = "enabled_by_default"
        case supportsProviderFilter = "supports_provider_filter"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? "recommendations"
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? itemID
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        // MA's model default is true.
        enabledByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .enabledByDefault)) ?? true
        supportsProviderFilter = (try? c.decodeIfPresent(Bool.self, forKey: .supportsProviderFilter)) ?? false
        uri = (try? c.decodeIfPresent(String.self, forKey: .uri)) ?? nil
    }
}

/// One item of `music/recommendations/items`, decoded by its `media_type`. A full item that does not decode falls
/// back to the slim `ItemMapping` shape; anything without even that is `.unknown`, so one odd item never fails the row.
public enum MARecommendationItem: Decodable, Hashable, Sendable {
    case artist(MAArtist)
    case album(MAAlbum)
    case track(MATrack)
    case playlist(MAPlaylist)
    /// Radio stations, podcasts, audiobooks, and items that are only mappings.
    case mapping(MAItemMapping)
    case unknown

    private enum Keys: String, CodingKey { case mediaType = "media_type" }

    public init(from decoder: any Decoder) throws {
        let mediaType = (try? decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .mediaType)) ?? nil
        switch mediaType {
        case "artist": if let item = try? MAArtist(from: decoder) { self = .artist(item); return }
        case "album": if let item = try? MAAlbum(from: decoder) { self = .album(item); return }
        case "track": if let item = try? MATrack(from: decoder) { self = .track(item); return }
        case "playlist": if let item = try? MAPlaylist(from: decoder) { self = .playlist(item); return }
        default: break
        }
        if let mapping = try? MAItemMapping(from: decoder) {
            self = .mapping(mapping)
        } else {
            self = .unknown
        }
    }
}

extension MARequest {
    /// Every row, without items.
    public static func recommendations() -> MARequest { MARequest(command: "music/recommendations") }

    /// One row's items. `provider` is the provider instance id that owns the row.
    public static func recommendationItems(provider: String, itemID: String) -> MARequest {
        MARequest(
            command: "music/recommendations/items",
            args: ["provider": .string(provider), "item_id": .string(itemID)])
    }
}
