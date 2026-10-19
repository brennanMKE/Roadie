import Foundation

public enum MAPlayerCommand: String, Hashable, Sendable {
    case play, pause, stop, next, previous
    case playPause = "play_pause"
}

public enum MARepeatMode: String, Hashable, Sendable {
    case off, one, all
}

public enum MAQueueOption: String, Hashable, Sendable {
    case play, replace, next, add
    case replaceNext = "replace_next"
}

/// One command and its arguments. Arg names are exactly those in `docs/ma-protocol/commands.json`.
public struct MARequest: Hashable, Sendable, CustomStringConvertible {
    public var command: String
    public var args: [String: MAJSON]
    /// Overrides the client's call timeout (long streamed results).
    public var timeout: Duration?

    public init(command: String, args: [String: MAJSON] = [:], timeout: Duration? = nil) {
        self.command = command
        self.args = args
        self.timeout = timeout
    }

    /// Command names only: arguments (the `auth` token above all) never reach a log or a description.
    public var description: String { command == "auth" ? "auth(redacted)" : command }

    public func encodedFrame(messageID: String) -> String {
        MAJSON.object([
            "message_id": .string(messageID),
            "command": .string(command),
            "args": .object(args),
        ]).encodedString()
    }
}

extension MARequest {
    public static func auth(token: MusicAssistantToken) -> MARequest {
        MARequest(command: "auth", args: ["token": .string(token.rawValue)])
    }

    public static func info() -> MARequest { MARequest(command: "info") }
    public static func time() -> MARequest { MARequest(command: "time") }
    public static func providers(type: String = "music") -> MARequest {
        MARequest(command: "providers", args: ["provider_type": .string(type)])
    }

    // MARK: Library

    public static func libraryItems(
        _ kind: MAMediaKind, limit: Int, offset: Int, orderBy: String? = "sort_name", albumArtistsOnly: Bool = false
    ) -> MARequest {
        var args: [String: MAJSON] = ["limit": .number(Double(limit)), "offset": .number(Double(offset))]
        if let orderBy { args["order_by"] = .string(orderBy) }
        if albumArtistsOnly { args["album_artists_only"] = .bool(true) }
        return MARequest(command: "music/\(kind.plural)/library_items", args: args)
    }

    /// Must carry the same filters as the listing it counts (the recorded artist last page was empty for want of it).
    public static func count(_ kind: MAMediaKind, albumArtistsOnly: Bool = false) -> MARequest {
        MARequest(
            command: "music/\(kind.plural)/count", args: albumArtistsOnly ? ["album_artists_only": .bool(true)] : [:])
    }

    public static func artistAlbums(itemID: String, provider: String) -> MARequest {
        MARequest(command: "music/artists/artist_albums", args: Self.itemArgs(itemID, provider))
    }

    public static func albumTracks(itemID: String, provider: String, inLibraryOnly: Bool = true) -> MARequest {
        var args = Self.itemArgs(itemID, provider)
        args["in_library_only"] = .bool(inLibraryOnly)
        return MARequest(command: "music/albums/album_tracks", args: args)
    }

    /// Streamed in chunks of 500; give it room.
    public static func playlistTracks(itemID: String, provider: String) -> MARequest {
        MARequest(
            command: "music/playlists/playlist_tracks", args: Self.itemArgs(itemID, provider), timeout: .seconds(60))
    }

    public static func itemByURI(_ uri: String) -> MARequest {
        MARequest(command: "music/item_by_uri", args: ["uri": .string(uri)])
    }

    public static func get(_ kind: MAMediaKind, itemID: String, provider: String) -> MARequest {
        MARequest(command: "music/\(kind.plural)/get", args: Self.itemArgs(itemID, provider))
    }

    public static func search(query: String, mediaTypes: [MAMediaKind], limit: Int) -> MARequest {
        MARequest(
            command: "music/search",
            args: [
                "search_query": .string(query),
                "media_types": .array(mediaTypes.map { .string($0.rawValue) }),
                "limit": .number(Double(limit)),
                "providers": .array([.string("library")]),
            ])
    }

    private static func itemArgs(_ itemID: String, _ provider: String) -> [String: MAJSON] {
        ["item_id": .string(itemID), "provider_instance_id_or_domain": .string(provider)]
    }

    // MARK: Players and queues

    public static func playersAll() -> MARequest { MARequest(command: "players/all") }
    public static func player(id: String) -> MARequest {
        MARequest(command: "players/get", args: ["player_id": .string(id)])
    }

    public static func queuesAll() -> MARequest { MARequest(command: "player_queues/all") }
    public static func queue(id: String) -> MARequest {
        MARequest(command: "player_queues/get", args: ["queue_id": .string(id)])
    }

    public static func activeQueue(playerID: String) -> MARequest {
        MARequest(command: "player_queues/get_active_queue", args: ["player_id": .string(playerID)])
    }

    public static func queueItems(id: String, limit: Int, offset: Int) -> MARequest {
        MARequest(
            command: "player_queues/items",
            args: ["queue_id": .string(id), "limit": .number(Double(limit)), "offset": .number(Double(offset))])
    }

    public static func playerCommand(_ command: MAPlayerCommand, playerID: String) -> MARequest {
        MARequest(command: "players/cmd/\(command.rawValue)", args: ["player_id": .string(playerID)])
    }

    public static func seek(playerID: String, position: Int) -> MARequest {
        MARequest(
            command: "players/cmd/seek", args: ["player_id": .string(playerID), "position": .number(Double(position))])
    }

    public static func volumeSet(playerID: String, level: Int) -> MARequest {
        MARequest(
            command: "players/cmd/volume_set",
            args: ["player_id": .string(playerID), "volume_level": .number(Double(level))])
    }

    public static func volumeMute(playerID: String, muted: Bool) -> MARequest {
        MARequest(command: "players/cmd/volume_mute", args: ["player_id": .string(playerID), "muted": .bool(muted)])
    }

    public static func shuffle(playerID: String, enabled: Bool) -> MARequest {
        MARequest(
            command: "players/cmd/shuffle", args: ["player_id": .string(playerID), "shuffle_enabled": .bool(enabled)])
    }

    public static func `repeat`(playerID: String, mode: MARepeatMode) -> MARequest {
        MARequest(
            command: "players/cmd/repeat", args: ["player_id": .string(playerID), "repeat_mode": .string(mode.rawValue)])
    }

    public static func playMedia(
        queueID: String, media: [String], option: MAQueueOption, startItem: String? = nil
    ) -> MARequest {
        var args: [String: MAJSON] = [
            "queue_id": .string(queueID),
            "media": .array(media.map { .string($0) }),
            "option": .string(option.rawValue),
        ]
        if let startItem { args["start_item"] = .string(startItem) }
        return MARequest(command: "player_queues/play_media", args: args)
    }
}
