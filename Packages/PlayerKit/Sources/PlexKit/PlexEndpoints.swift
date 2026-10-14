import Foundation

extension PlexClient {
    /// GET /identity
    public func identity() async throws -> PlexIdentity {
        let envelope: IdentityEnvelope = try await fetch(request(path: "/identity"))
        return envelope.container
    }

    /// GET /library/sections
    public func librarySections() async throws -> [PlexLibrarySection] {
        let envelope: MediaContainerEnvelope<PlexLibrarySection> = try await fetch(request(path: "/library/sections"))
        return envelope.container.directory ?? envelope.container.metadata ?? []
    }

    public func musicSections() async throws -> [PlexLibrarySection] {
        try await librarySections().filter(\.isMusic)
    }

    /// /library/sections/<id>/all?type=8
    public func artists(in section: PlexLibrarySection.ID, page: PlexPageRequest = .first) async throws -> PlexPage<PlexArtist> {
        try await list(request(path: "/library/sections/\(section)/all", query: [.init(name: "type", value: "8")], page: page),
                       page: page, as: PlexArtist.self)
    }

    /// /library/sections/<id>/all?type=9
    public func albums(in section: PlexLibrarySection.ID, page: PlexPageRequest = .first) async throws -> PlexPage<PlexAlbum> {
        try await list(request(path: "/library/sections/\(section)/all", query: [.init(name: "type", value: "9")], page: page),
                       page: page, as: PlexAlbum.self)
    }

    /// /library/sections/<id>/all?type=10
    public func tracks(in section: PlexLibrarySection.ID, page: PlexPageRequest = .first) async throws -> PlexPage<PlexTrack> {
        try await list(request(path: "/library/sections/\(section)/all", query: [.init(name: "type", value: "10")], page: page),
                       page: page, as: PlexTrack.self)
    }

    /// /library/sections/<id>/all?type=10&title=...
    ///
    /// Plex matches `title` by word prefix, not substring; the caller decides what to search for.
    public func searchTracks(in section: PlexLibrarySection.ID, title: String, page: PlexPageRequest = .first) async throws -> PlexPage<PlexTrack> {
        let query = [URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "title", value: title)]
        return try await list(request(path: "/library/sections/\(section)/all", query: query, page: page),
                              page: page, as: PlexTrack.self)
    }

    /// /library/sections/<id>/all?type=8&title=...
    public func searchArtists(in section: PlexLibrarySection.ID, title: String, page: PlexPageRequest = .first) async throws -> PlexPage<PlexArtist> {
        let query = [URLQueryItem(name: "type", value: "8"), URLQueryItem(name: "title", value: title)]
        return try await list(request(path: "/library/sections/\(section)/all", query: query, page: page),
                              page: page, as: PlexArtist.self)
    }

    /// /library/sections/<id>/all?type=9&title=...
    public func searchAlbums(in section: PlexLibrarySection.ID, title: String, page: PlexPageRequest = .first) async throws -> PlexPage<PlexAlbum> {
        let query = [URLQueryItem(name: "type", value: "9"), URLQueryItem(name: "title", value: title)]
        return try await list(request(path: "/library/sections/\(section)/all", query: query, page: page),
                              page: page, as: PlexAlbum.self)
    }

    /// /library/metadata/<artist>/children
    public func albums(of artist: PlexArtist.ID, page: PlexPageRequest = .first) async throws -> PlexPage<PlexAlbum> {
        try await list(request(path: "/library/metadata/\(artist)/children", page: page), page: page, as: PlexAlbum.self)
    }

    /// /library/metadata/<album>/children
    public func tracks(of album: PlexAlbum.ID, page: PlexPageRequest = .first) async throws -> PlexPage<PlexTrack> {
        try await list(request(path: "/library/metadata/\(album)/children", page: page), page: page, as: PlexTrack.self)
    }
}
