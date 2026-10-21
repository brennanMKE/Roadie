import Foundation

public enum MediaKind: String, Hashable, Sendable, Codable, CaseIterable {
    case artist, album, track, playlist
}

/// A backend's own identifier for an item: a Music Assistant `library://` URI, a folder path.
public struct MediaID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var kind: MediaKind
    public var rawValue: String

    public init(_ kind: MediaKind, _ rawValue: String) {
        self.kind = kind
        self.rawValue = rawValue
    }

    public var description: String { "\(kind.rawValue):\(rawValue)" }
}

/// Opaque to the UI; the backend that produced it knows how to fetch it.
public struct ArtworkRef: Hashable, Sendable, Codable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct LibraryArtist: Identifiable, Hashable, Sendable {
    public var id: MediaID
    public var name: String
    public var sortName: String?
    public var artwork: ArtworkRef?

    public init(id: MediaID, name: String, sortName: String? = nil, artwork: ArtworkRef? = nil) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.artwork = artwork
    }
}

public struct LibraryAlbum: Identifiable, Hashable, Sendable {
    public var id: MediaID
    public var title: String
    public var artistID: MediaID?
    public var artistName: String?
    public var year: Int?
    public var trackCount: Int?
    public var artwork: ArtworkRef?

    public init(
        id: MediaID, title: String, artistID: MediaID? = nil, artistName: String? = nil,
        year: Int? = nil, trackCount: Int? = nil, artwork: ArtworkRef? = nil
    ) {
        self.id = id
        self.title = title
        self.artistID = artistID
        self.artistName = artistName
        self.year = year
        self.trackCount = trackCount
        self.artwork = artwork
    }
}

public struct LibraryTrack: Identifiable, Hashable, Sendable {
    public var id: MediaID
    public var title: String
    public var artistID: MediaID?
    public var artistName: String
    public var albumID: MediaID?
    public var albumName: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval?
    /// kbps
    public var bitrate: Int?
    /// Hz
    public var sampleRate: Double?
    public var channels: Int?
    public var artwork: ArtworkRef?

    public init(
        id: MediaID, title: String, artistID: MediaID? = nil, artistName: String,
        albumID: MediaID? = nil, albumName: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
        duration: TimeInterval? = nil, bitrate: Int? = nil, sampleRate: Double? = nil, channels: Int? = nil,
        artwork: ArtworkRef? = nil
    ) {
        self.id = id
        self.title = title
        self.artistID = artistID
        self.artistName = artistName
        self.albumID = albumID
        self.albumName = albumName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.artwork = artwork
    }
}

public struct LibraryPlaylist: Identifiable, Hashable, Sendable {
    public var id: MediaID
    public var name: String
    public var trackCount: Int?
    public var artwork: ArtworkRef?

    public init(id: MediaID, name: String, trackCount: Int? = nil, artwork: ArtworkRef? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.artwork = artwork
    }
}

public struct SearchResults: Hashable, Sendable {
    public var artists: [LibraryArtist]
    public var albums: [LibraryAlbum]
    public var tracks: [LibraryTrack]

    public init(artists: [LibraryArtist] = [], albums: [LibraryAlbum] = [], tracks: [LibraryTrack] = []) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }

    public static let empty = SearchResults()
    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }
}

/// One Music Assistant player's playback as SkinAmp sees it (#0121). SkinAmp's own player is `OutputDevice.thisMacID`.
public struct OutputActivity: Hashable, Sendable {
    public var output: OutputDevice.ID
    public var name: String
    public var state: NowPlaying.State
    /// The group or sync leader this player plays as a member of; nil when it plays its own queue.
    public var leader: OutputDevice.ID?
    /// Server time of the last state or position change; for "most recent" when several play.
    public var updatedAt: Double?

    public init(
        output: OutputDevice.ID, name: String, state: NowPlaying.State, leader: OutputDevice.ID? = nil,
        updatedAt: Double? = nil
    ) {
        self.output = output
        self.name = name
        self.state = state
        self.leader = leader
        self.updatedAt = updatedAt
    }
}
