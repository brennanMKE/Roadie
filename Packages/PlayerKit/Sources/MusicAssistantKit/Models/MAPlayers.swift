import Foundation

public enum MAPlaybackState: Hashable, Sendable {
    case idle, paused, playing
    /// Anything a newer server adds.
    case unknown

    public init(_ raw: String?) {
        switch raw {
        case "idle": self = .idle
        case "paused": self = .paused
        case "playing": self = .playing
        default: self = .unknown
        }
    }
}

/// `Player.current_media`. Unrecorded while a track plays except for the Sendspin web player; every field optional.
public struct MAPlayerMedia: Codable, Hashable, Sendable {
    public var uri: String?
    public var mediaType: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var imageURL: String?
    public var duration: Double?
    public var elapsedTime: Double?
    public var elapsedTimeLastUpdated: Double?
    public var queueItemID: String?

    enum CodingKeys: String, CodingKey {
        case uri
        case mediaType = "media_type"
        case title, artist, album
        case imageURL = "image_url"
        case duration
        case elapsedTime = "elapsed_time"
        case elapsedTimeLastUpdated = "elapsed_time_last_updated"
        case queueItemID = "queue_item_id"
    }
}

public struct MAPlayer: Codable, Hashable, Sendable {
    public var playerID: String
    public var provider: String?
    /// `player`, `group`, `stereo_pair`.
    public var type: String?
    public var name: String
    public var displayName: String?
    public var available: Bool
    public var enabled: Bool?
    public var hideInUI: Bool?
    public var playbackState: String?
    public var elapsedTime: Double?
    public var elapsedTimeLastUpdated: Double?
    public var powered: Bool?
    /// Null for universal players.
    public var volumeLevel: Double?
    public var volumeMuted: Bool?
    /// Unrecorded on the reference server; a non-empty list marks the player as a group (`OutputDevice.isGroup`).
    public var groupMembers: [String]?
    public var syncedTo: String?
    public var activeGroup: String?
    public var supportedFeatures: [String]?
    public var currentMedia: MAPlayerMedia?
    public var needsSetup: Bool?

    public var state: MAPlaybackState { MAPlaybackState(playbackState) }

    enum CodingKeys: String, CodingKey {
        case playerID = "player_id"
        case provider, type, name
        case displayName = "display_name"
        case available, enabled
        case hideInUI = "hide_in_ui"
        case playbackState = "playback_state"
        case elapsedTime = "elapsed_time"
        case elapsedTimeLastUpdated = "elapsed_time_last_updated"
        case powered
        case volumeLevel = "volume_level"
        case volumeMuted = "volume_muted"
        case groupMembers = "group_members"
        case syncedTo = "synced_to"
        case activeGroup = "active_group"
        case supportedFeatures = "supported_features"
        case currentMedia = "current_media"
        case needsSetup = "needs_setup"
    }
}

/// An entry of `player_queues/items` or a queue's `current_item`/`next_item`. The media item stays raw (unrecorded).
public struct MAQueueItem: Codable, Hashable, Sendable {
    public var queueID: String?
    public var queueItemID: String
    public var name: String?
    public var duration: Double?
    public var mediaItem: MAJSON?
    public var image: MAMediaItemImage?
    public var index: Int?
    public var available: Bool?

    enum CodingKeys: String, CodingKey {
        case queueID = "queue_id"
        case queueItemID = "queue_item_id"
        case name, duration
        case mediaItem = "media_item"
        case image, index, available
    }
}

public struct MAPlayerQueue: Codable, Hashable, Sendable {
    public var queueID: String
    public var active: Bool?
    public var displayName: String?
    public var available: Bool?
    /// A count, not the contents (`player_queues/items` has those).
    public var items: Int?
    public var shuffleEnabled: Bool?
    public var repeatMode: String?
    public var currentIndex: Int?
    public var elapsedTime: Double?
    public var elapsedTimeLastUpdated: Double?
    public var state: String?
    public var currentItem: MAQueueItem?
    public var nextItem: MAQueueItem?

    enum CodingKeys: String, CodingKey {
        case queueID = "queue_id"
        case active
        case displayName = "display_name"
        case available, items
        case shuffleEnabled = "shuffle_enabled"
        case repeatMode = "repeat_mode"
        case currentIndex = "current_index"
        case elapsedTime = "elapsed_time"
        case elapsedTimeLastUpdated = "elapsed_time_last_updated"
        case state
        case currentItem = "current_item"
        case nextItem = "next_item"
    }
}
