import Foundation

/// Backends without favorites have no favorites to list (#0142).
extension MusicBackend {
    public func favoriteCount(_ kind: MediaKind) async throws -> Int? {
        throw MusicBackendError.unsupported(.favorites)
    }

    public func favoriteTracks(page: PageRequest) async throws -> Page<LibraryTrack> {
        throw MusicBackendError.unsupported(.favorites)
    }

    public func favoriteAlbums(page: PageRequest) async throws -> Page<LibraryAlbum> {
        throw MusicBackendError.unsupported(.favorites)
    }

    public func favoriteArtists(page: PageRequest) async throws -> Page<LibraryArtist> {
        throw MusicBackendError.unsupported(.favorites)
    }

    public func favoritePlaylists(page: PageRequest) async throws -> Page<LibraryPlaylist> {
        throw MusicBackendError.unsupported(.favorites)
    }
}
