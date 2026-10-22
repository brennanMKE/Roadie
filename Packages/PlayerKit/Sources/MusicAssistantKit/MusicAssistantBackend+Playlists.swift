import Foundation
import MusicBackendKit

/// Playlist writes (#0135, #0136). Every command goes through `write(_:)`: a server error 12 removes the
/// command for the session (`.unsupported`), a scope or permission refusal reads as `.forbidden`.
extension MusicAssistantBackend {
    public func createPlaylist(named name: String) async throws -> LibraryPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicBackendError.backend("A playlist needs a name.") }
        let created = try await write(.createPlaylist(name: trimmed))
        do {
            return LibraryPlaylist(ma: try created.decode(as: MAPlaylist.self), canReorder: canReorderPlaylists)
        } catch {
            throw MusicBackendError.backend("Music Assistant's answer could not be read.")
        }
    }

    /// Sends the playlist as the server has it, with the new name and `overwrite: true`.
    public func renamePlaylist(_ id: MediaID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicBackendError.backend("A playlist needs a name.") }
        let (uri, raw, playlist) = try await fetchPlaylist(id)
        guard playlist.source != .builtIn else {
            throw MusicBackendError.forbidden("Built-in playlists can't be renamed.")
        }
        guard var object = raw.objectValue else { throw MusicBackendError.notFound(id) }
        object["name"] = .string(trimmed)
        _ = try await write(.updatePlaylist(itemID: uri.itemID, playlist: .object(object), overwrite: true))
    }

    /// `music/library/remove_item`; built-in playlists are refused here (the server would hide them in its own UI).
    public func deletePlaylist(_ id: MediaID) async throws {
        let (_, _, playlist) = try await fetchPlaylist(id)
        guard playlist.source != .builtIn else {
            throw MusicBackendError.forbidden("Built-in playlists can't be deleted.")
        }
        guard let libraryID = playlist.libraryID else { throw MusicBackendError.notFound(id) }
        _ = try await write(.removeLibraryItem(mediaType: .playlist, libraryItemID: libraryID))
    }

    /// One `add_playlist_tracks` with the items' URIs as given (albums expand server-side); artists are left out.
    /// A playlist whose tracks can't be edited is refused here.
    public func add(_ items: [MediaID], toPlaylist id: MediaID) async throws {
        let uris = items.filter { $0.kind == .track || $0.kind == .album }.map(\.rawValue)
        guard !uris.isEmpty else { return }
        let (_, _, playlist) = try await fetchPlaylist(id)
        guard playlist.editing.contains(.addRemove) else {
            throw MusicBackendError.forbidden("\u{201C}\(playlist.name)\u{201D} is read-only.")
        }
        guard let libraryID = playlist.libraryID else { throw MusicBackendError.notFound(id) }
        _ = try await write(.addPlaylistTracks(playlistID: libraryID, uris: uris))
    }

    // MARK: M3U (#0148)

    public func exportPlaylist(_ id: MediaID) async throws -> String {
        let (_, _, playlist) = try await fetchPlaylist(id)
        guard let libraryID = playlist.libraryID else { throw MusicBackendError.notFound(id) }
        let result = try await write(.exportPlaylist(playlistID: libraryID))
        guard let text = result.stringValue else {
            throw MusicBackendError.backend("Music Assistant's answer could not be read.")
        }
        return text
    }

    public func importPlaylist(m3u: String) async throws -> LibraryPlaylist {
        guard !m3u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicBackendError.backend("The playlist file is empty.")
        }
        let created = try await write(.importPlaylist(m3u: m3u, libraryMatching: true))
        do {
            return LibraryPlaylist(ma: try created.decode(as: MAPlaylist.self), canReorder: canReorderPlaylists)
        } catch {
            throw MusicBackendError.backend("Music Assistant's answer could not be read.")
        }
    }

    /// One `remove_playlist_tracks` with the 1-based positions, highest first (#0138).
    public func remove(positions: [Int], fromPlaylist id: MediaID) async throws {
        let positions = Set(positions).sorted(by: >)
        guard !positions.isEmpty else { return }
        let libraryID = try await editablePlaylistID(id)
        _ = try await write(.removePlaylistTracks(playlistID: libraryID, positions: positions))
    }

    /// `move_playlist_track` (1-based); refused without a request when the server lacks the command (2.10.6).
    public func movePlaylistTrack(_ id: MediaID, from: Int, to: Int) async throws {
        guard supports(MARequest.movePlaylistTrackCommand) else {
            throw MusicBackendError.unsupported(.playlistEditing)
        }
        guard from != to else { return }
        let libraryID = try await editablePlaylistID(id)
        _ = try await write(.movePlaylistTrack(playlistID: libraryID, from: from, to: to))
    }

    // MARK: Helpers

    /// The library id of a playlist whose tracks can be edited.
    private func editablePlaylistID(_ id: MediaID) async throws -> String {
        let (_, _, playlist) = try await fetchPlaylist(id)
        guard playlist.editing.contains(.addRemove) else {
            throw MusicBackendError.forbidden("\u{201C}\(playlist.name)\u{201D} is read-only.")
        }
        guard let libraryID = playlist.libraryID else { throw MusicBackendError.notFound(id) }
        return libraryID
    }

    /// Whether playlists from this server can be reordered (the command probe, #0137).
    var canReorderPlaylists: Bool { supports(MARequest.movePlaylistTrackCommand) }

    /// The playlist as the server has it now: its URI, the raw object (for `update`) and the mapped value.
    func fetchPlaylist(_ id: MediaID) async throws -> (MAURI, MAJSON, LibraryPlaylist) {
        guard let uri = MAURI.parse(id.rawValue), uri.mediaType == .playlist else {
            throw MusicBackendError.notFound(id)
        }
        let raw = try await write(.get(.playlist, itemID: uri.itemID, provider: uri.provider))
        guard let decoded = try? raw.decode(as: MAPlaylist.self) else { throw MusicBackendError.notFound(id) }
        return (uri, raw, LibraryPlaylist(ma: decoded, canReorder: canReorderPlaylists))
    }

    /// `perform(_:)` plus the scope rule.
    func write(_ request: MARequest) async throws -> MAJSON {
        guard let client else { throw MusicBackendError.notConnected }
        do {
            return try await client.call(request)
        } catch {
            if case MusicAssistantError.server(let code, let details) = error,
               code != MAServerCommands.unsupportedCommandCode, Self.isPermissionRefusal(details) {
                throw MusicBackendError.forbidden(details)
            }
            throw noteUnsupported(error, command: request.command)
        }
    }

    static func isPermissionRefusal(_ details: String) -> Bool {
        let lowered = details.lowercased()
        return lowered.contains("scope") || lowered.contains("permission")
    }
}
