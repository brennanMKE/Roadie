import Foundation
import MusicBackendKit

/// A small in-memory library: the data `StubMusicBackend` answers from.
public struct StubLibrary: Hashable, Sendable {
    public var artists: [LibraryArtist]
    public var albums: [LibraryAlbum]
    public var tracks: [LibraryTrack]
    public var playlists: [LibraryPlaylist]
    public var playlistTracks: [MediaID: [MediaID]]

    public init(
        artists: [LibraryArtist] = [], albums: [LibraryAlbum] = [], tracks: [LibraryTrack] = [],
        playlists: [LibraryPlaylist] = [], playlistTracks: [MediaID: [MediaID]] = [:]
    ) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
        self.playlists = playlists
        self.playlistTracks = playlistTracks
    }

    /// "Artist 01"... with `albumsPerArtist` albums "Artist 01 - Album 1" and `tracksPerAlbum` tracks each.
    /// Ids are `MediaID(.artist, "a01")`, `(.album, "a01-b1")`, `(.track, "a01-b1-t01")`;
    /// durations are 120 + n seconds, bitrate 320, channels 2.
    public static func sample(
        artistCount: Int = 25, albumsPerArtist: Int = 2, tracksPerAlbum: Int = 5, playlistCount: Int = 0
    ) -> StubLibrary {
        var library = StubLibrary()
        for a in 1...max(1, artistCount) where artistCount > 0 {
            let artistName = String(format: "Artist %02d", a)
            let artistID = MediaID(.artist, String(format: "a%02d", a))
            library.artists.append(LibraryArtist(id: artistID, name: artistName, sortName: artistName))
            for b in 1...max(1, albumsPerArtist) where albumsPerArtist > 0 {
                let albumName = "\(artistName) \u{2013} Album \(b)"
                let albumID = MediaID(.album, "\(artistID.rawValue)-b\(b)")
                library.albums.append(LibraryAlbum(
                    id: albumID, title: albumName, artistID: artistID, artistName: artistName,
                    year: 1990 + b, trackCount: tracksPerAlbum))
                for t in 1...max(1, tracksPerAlbum) where tracksPerAlbum > 0 {
                    library.tracks.append(LibraryTrack(
                        id: MediaID(.track, "\(albumID.rawValue)-t" + String(format: "%02d", t)),
                        title: "\(albumName) \u{2013} Track \(t)", artistID: artistID, artistName: artistName,
                        albumID: albumID, albumName: albumName, trackNumber: t, discNumber: 1,
                        duration: TimeInterval(120 + t), bitrate: 320, sampleRate: 44_100, channels: 2))
                }
            }
        }
        if playlistCount > 0 {
            for p in 1...playlistCount {
                let id = MediaID(.playlist, String(format: "p%02d", p))
                let members = library.tracks.prefix(3).map(\.id)
                library.playlists.append(LibraryPlaylist(id: id, name: "Playlist \(p)", trackCount: members.count))
                library.playlistTracks[id] = Array(members)
            }
        }
        return library
    }

    public func albums(of artist: MediaID?) -> [LibraryAlbum] {
        guard let artist else { return albums }
        return albums.filter { $0.artistID == artist }
    }

    /// In track-number order as stored. Empty for an unknown album.
    public func tracks(of album: MediaID) -> [LibraryTrack] {
        tracks.filter { $0.albumID == album }
    }

    /// Case-insensitive `contains` on names and titles, each kind capped at `limit`.
    public func search(_ query: String, limit: Int) -> SearchResults {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return .empty }
        return SearchResults(
            artists: Array(artists.filter { $0.name.lowercased().contains(needle) }.prefix(limit)),
            albums: Array(albums.filter { $0.title.lowercased().contains(needle) }.prefix(limit)),
            tracks: Array(tracks.filter { $0.title.lowercased().contains(needle) }.prefix(limit)))
    }
}
