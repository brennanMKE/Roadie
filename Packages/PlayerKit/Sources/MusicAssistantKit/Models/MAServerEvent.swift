import Foundation

/// A pushed message: `{"event": ..., "object_id"?: ..., "data": ...}`.
///
/// UNVERIFIED until #0076 records one: no event was captured in #0060, so the shape comes from the API page.
/// Decoding is lenient on purpose: `object_id` is optional and `data` stays raw (`.null` when absent).
public struct MAServerEvent: Hashable, Sendable {
    public var event: String
    public var objectID: String?
    public var data: MAJSON

    public init(event: String, objectID: String? = nil, data: MAJSON = .null) {
        self.event = event
        self.objectID = objectID
        self.data = data
    }

    init?(json: MAJSON) {
        guard case .object(let object) = json, let name = object["event"]?.stringValue else { return nil }
        self.init(event: name, objectID: object["object_id"]?.stringValue, data: object["data"] ?? .null)
    }

    /// The names the API page lists.
    public static let knownNames: Set<String> = [
        "player_added", "player_updated", "player_removed", "player_config_updated",
        "queue_added", "queue_updated", "queue_items_updated", "queue_time_updated",
        "media_item_added", "media_item_updated", "media_item_deleted", "media_item_played",
        "providers_updated", "tasks_updated", "music_sync_completed", "application_shutdown",
    ]
}
