import Foundation

/// Playlist writes (#0135, #0136). Arg names are exactly those in `docs/ma-protocol/commands.json`.
extension MARequest {
    /// `provider_instance_or_domain` (not `_id_or_domain`); nil lets the server pick (its builtin provider).
    public static func createPlaylist(name: String, provider: String? = nil) -> MARequest {
        var args: [String: MAJSON] = ["name": .string(name)]
        if let provider { args["provider_instance_or_domain"] = .string(provider) }
        return MARequest(command: "music/playlists/create_playlist", args: args)
    }

    /// `playlist` is the whole object as the server sent it, with the changed fields; `overwrite` makes the
    /// server take the new name (it keeps the old one otherwise).
    public static func updatePlaylist(itemID: String, playlist: MAJSON, overwrite: Bool = true) -> MARequest {
        MARequest(
            command: "music/playlists/update",
            args: ["item_id": .string(itemID), "update": playlist, "overwrite": .bool(overwrite)])
    }

    /// Deletes a library item (for a playlist: the playlist itself, on every app).
    public static func removeLibraryItem(mediaType: MAMediaKind, libraryItemID: String) -> MARequest {
        MARequest(
            command: "music/library/remove_item",
            args: ["media_type": .string(mediaType.rawValue), "library_item_id": .string(libraryItemID)])
    }

    /// `db_playlist_id` is the library id. Album and playlist URIs expand server-side; duplicates are skipped.
    public static func addPlaylistTracks(playlistID: String, uris: [String]) -> MARequest {
        MARequest(
            command: "music/playlists/add_playlist_tracks",
            args: ["db_playlist_id": .string(playlistID), "uris": .array(uris.map { .string($0) })])
    }
}
