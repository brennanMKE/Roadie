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
}
