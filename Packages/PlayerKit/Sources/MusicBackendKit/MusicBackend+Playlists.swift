import Foundation

/// Backends without playlist editing refuse every write (#0135, #0136).
extension MusicBackend {
    public func createPlaylist(named name: String) async throws -> LibraryPlaylist {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func renamePlaylist(_ id: MediaID, to name: String) async throws {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func deletePlaylist(_ id: MediaID) async throws {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func add(_ items: [MediaID], toPlaylist id: MediaID) async throws {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func exportPlaylist(_ id: MediaID) async throws -> String {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func importPlaylist(m3u: String) async throws -> LibraryPlaylist {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func remove(positions: [Int], fromPlaylist id: MediaID) async throws {
        throw MusicBackendError.unsupported(.playlistEditing)
    }

    public func movePlaylistTrack(_ id: MediaID, from: Int, to: Int) async throws {
        throw MusicBackendError.unsupported(.playlistEditing)
    }
}
