import Foundation

/// A library change made elsewhere (another app, Music Assistant's web UI) or confirming an own write (#0139).
/// Every change is a hint to refetch, never the data itself: the event envelopes are unverified (#0076).
public enum LibraryChange: Hashable, Sendable {
    case playlistAdded(MediaID)
    case playlistUpdated(MediaID)
    case playlistDeleted(MediaID)
    /// `nil` when the event didn't say which way.
    case favoriteChanged(MediaID, Bool?)
    /// Something was played: a refresh hint for Discover rows.
    case played
}

public enum MediaKind: String, Hashable, Sendable, Codable, CaseIterable {
    case artist, album, track, playlist, radio
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
    /// nil when the backend doesn't say.
    public var isFavorite: Bool?

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
    /// nil when the backend doesn't say.
    public var isFavorite: Bool?

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
    /// nil when the backend doesn't say.
    public var isFavorite: Bool?
    /// 1-based position within the playlist it was fetched from; nil outside a playlist.
    public var playlistPosition: Int?

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

/// What can be done to a playlist; the backend fills it from the playlist's flags and the server's features.
public struct PlaylistEditing: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let addRemove = PlaylistEditing(rawValue: 1 << 0)
    public static let reorder = PlaylistEditing(rawValue: 1 << 1)
    public static let rename = PlaylistEditing(rawValue: 1 << 2)
    public static let delete = PlaylistEditing(rawValue: 1 << 3)
}

/// Where a playlist lives: the user's own, one the server builds itself, or a streaming provider's.
public enum PlaylistSource: Hashable, Sendable {
    case user
    case builtIn
    /// A provider's display name, e.g. "Spotify".
    case provider(name: String)
}

public struct LibraryPlaylist: Identifiable, Hashable, Sendable {
    public var id: MediaID
    public var name: String
    public var trackCount: Int?
    public var artwork: ArtworkRef?
    /// Tracks can be added and removed (the server's flag).
    public var isEditable: Bool
    /// Endless and provider-driven: its tracks are a sample.
    public var isDynamic: Bool
    /// A display name, not a user id.
    public var owner: String?
    public var source: PlaylistSource
    public var editing: PlaylistEditing
    public var isFavorite: Bool?
    /// The backend's database id, for edits; nil when the playlist isn't in the library.
    public var libraryID: String?

    public init(
        id: MediaID, name: String, trackCount: Int? = nil, artwork: ArtworkRef? = nil, isEditable: Bool = false,
        isDynamic: Bool = false, owner: String? = nil, source: PlaylistSource = .user, editing: PlaylistEditing = [],
        isFavorite: Bool? = nil, libraryID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.artwork = artwork
        self.isEditable = isEditable
        self.isDynamic = isDynamic
        self.owner = owner
        self.source = source
        self.editing = editing
        self.isFavorite = isFavorite
        self.libraryID = libraryID
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
