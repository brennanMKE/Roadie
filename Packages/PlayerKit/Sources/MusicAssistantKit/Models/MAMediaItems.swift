import Foundation

public struct MAMediaItemImage: Codable, Hashable, Sendable {
    public var type: String?
    public var path: String?
    public var provider: String?
    public var remotelyAccessible: Bool?
    public var proxyID: String?

    enum CodingKeys: String, CodingKey {
        case type, path, provider
        case remotelyAccessible = "remotely_accessible"
        case proxyID = "proxy_id"
    }
}

/// Only the parts the app reads; every other metadata key is ignored. `{}` and `null` both decode.
public struct MAMetadata: Codable, Hashable, Sendable {
    public var images: [MAMediaItemImage]?
    public var genres: [String]?
}

public struct MAAudioFormat: Codable, Hashable, Sendable {
    public var contentType: String?
    public var codecType: String?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?
    public var bitRate: Int?

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case codecType = "codec_type"
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case channels
        case bitRate = "bit_rate"
    }
}

public struct MAProviderMapping: Codable, Hashable, Sendable {
    public var itemID: String
    public var providerDomain: String?
    public var providerInstance: String?
    public var available: Bool?
    public var inLibrary: Bool?
    public var audioFormat: MAAudioFormat?
    public var url: String?
    public var details: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case providerDomain = "provider_domain"
        case providerInstance = "provider_instance"
        case available
        case inLibrary = "in_library"
        case audioFormat = "audio_format"
        case url, details
    }
}

/// The slim `artists[]` / `album` shape nested inside albums and tracks.
public struct MAItemMapping: Codable, Hashable, Sendable {
    public var itemID: String
    public var provider: String?
    public var name: String
    public var uri: String
    public var mediaType: String?
    public var sortName: String?
    public var version: String?
    public var available: Bool?
    public var image: MAMediaItemImage?
    public var year: Int?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, uri
        case mediaType = "media_type"
        case sortName = "sort_name"
        case version, available, image, year
    }
}

public struct MAArtist: Codable, Hashable, Sendable {
    public var itemID: String
    public var provider: String?
    public var name: String
    public var uri: String
    public var mediaType: String?
    public var sortName: String?
    public var providerMappings: [MAProviderMapping]?
    public var metadata: MAMetadata?
    public var favorite: Bool?
    public var available: Bool?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, uri
        case mediaType = "media_type"
        case sortName = "sort_name"
        case providerMappings = "provider_mappings"
        case metadata, favorite, available
    }
}

public struct MAAlbum: Codable, Hashable, Sendable {
    public var itemID: String
    public var provider: String?
    public var name: String
    public var uri: String
    public var mediaType: String?
    public var sortName: String?
    public var providerMappings: [MAProviderMapping]?
    public var metadata: MAMetadata?
    public var favorite: Bool?
    public var available: Bool?
    public var year: Int?
    public var artists: [MAItemMapping]?
    public var albumType: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, uri
        case mediaType = "media_type"
        case sortName = "sort_name"
        case providerMappings = "provider_mappings"
        case metadata, favorite, available, year, artists
        case albumType = "album_type"
    }
}

public struct MATrack: Codable, Hashable, Sendable {
    public var itemID: String
    public var provider: String?
    public var name: String
    public var uri: String
    public var mediaType: String?
    public var sortName: String?
    public var providerMappings: [MAProviderMapping]?
    public var metadata: MAMetadata?
    public var favorite: Bool?
    public var available: Bool?
    /// Seconds.
    public var duration: Double?
    public var artists: [MAItemMapping]?
    public var album: MAItemMapping?
    public var discNumber: Int?
    public var trackNumber: Int?
    /// 1-based position, present on `music/playlists/playlist_tracks` rows.
    public var position: Int?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, uri
        case mediaType = "media_type"
        case sortName = "sort_name"
        case providerMappings = "provider_mappings"
        case metadata, favorite, available, duration, artists, album, position
        case discNumber = "disc_number"
        case trackNumber = "track_number"
    }
}

public struct MAPlaylist: Codable, Hashable, Sendable {
    public var itemID: String
    public var provider: String?
    public var name: String
    public var uri: String
    public var mediaType: String?
    public var sortName: String?
    public var providerMappings: [MAProviderMapping]?
    public var metadata: MAMetadata?
    public var favorite: Bool?
    public var available: Bool?
    public var owner: String?
    public var isEditable: Bool?
    public var isDynamic: Bool?
    /// Media types the playlist can hold; the server's default is `["track"]`.
    public var supportedMediatypes: [String]?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case provider, name, uri
        case mediaType = "media_type"
        case sortName = "sort_name"
        case providerMappings = "provider_mappings"
        case metadata, favorite, available, owner
        case isEditable = "is_editable"
        case isDynamic = "is_dynamic"
        case supportedMediatypes = "supported_mediatypes"
    }
}

/// `music/search`: only the four kinds the app uses; the other five keys are ignored.
public struct MASearchResults: Codable, Hashable, Sendable {
    public var artists: [MAArtist]
    public var albums: [MAAlbum]
    public var tracks: [MATrack]
    public var playlists: [MAPlaylist]

    public init(artists: [MAArtist] = [], albums: [MAAlbum] = [], tracks: [MATrack] = [], playlists: [MAPlaylist] = []) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
    }

    enum CodingKeys: String, CodingKey { case artists, albums, tracks, playlists }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artists = try container.decodeIfPresent([MAArtist].self, forKey: .artists) ?? []
        albums = try container.decodeIfPresent([MAAlbum].self, forKey: .albums) ?? []
        tracks = try container.decodeIfPresent([MATrack].self, forKey: .tracks) ?? []
        playlists = try container.decodeIfPresent([MAPlaylist].self, forKey: .playlists) ?? []
    }
}
