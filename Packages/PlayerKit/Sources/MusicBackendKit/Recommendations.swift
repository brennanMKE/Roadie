import Foundation

/// One of the server's automatic rows ("Recently played", "Random albums", a streaming provider's mix), shown under
/// Discover (#0143). Ids are opaque: the UI shows `name`, `subtitle` and `icon`.
public struct RecommendationRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case shelf, timeline }

    /// `provider + "/" + itemID`.
    public var id: String { provider + "/" + itemID }
    public var provider: String
    public var itemID: String
    public var name: String
    public var subtitle: String?
    /// The server's icon name (Material Design, e.g. `mdi-album`); `MDIIcon.symbol` maps it.
    public var icon: String?
    public var isEnabledByDefault: Bool
    public var kind: Kind
    /// A streaming provider's display name, for a tooltip; nil for the library's own rows.
    public var providerName: String?

    public init(
        provider: String, itemID: String, name: String, subtitle: String? = nil, icon: String? = nil,
        isEnabledByDefault: Bool = true, kind: Kind = .shelf, providerName: String? = nil
    ) {
        self.provider = provider
        self.itemID = itemID
        self.name = name
        self.subtitle = subtitle
        self.icon = icon
        self.isEnabledByDefault = isEnabledByDefault
        self.kind = kind
        self.providerName = providerName
    }
}

/// One item of a row: rows mix kinds. `.other` is an item the server sent only a slim mapping for (or a kind
/// Roadie does not browse, like a radio station or a podcast): it carries what the mapping has.
public enum RecommendationItem: Identifiable, Hashable, Sendable {
    case artist(LibraryArtist)
    case album(LibraryAlbum)
    case track(LibraryTrack)
    case playlist(LibraryPlaylist)
    /// `kind` is nil for a media type Roadie has no `MediaKind` for; such an item can't be played or queued.
    case other(uri: String, kind: MediaKind?, name: String, subtitle: String?, artwork: ArtworkRef?)

    public var id: String {
        switch self {
        case .artist(let artist): artist.id.rawValue
        case .album(let album): album.id.rawValue
        case .track(let track): track.id.rawValue
        case .playlist(let playlist): playlist.id.rawValue
        case .other(let uri, _, _, _, _): uri
        }
    }

    /// What `play(_:on:mode:)` takes; nil when the item can't be played.
    public var mediaID: MediaID? {
        switch self {
        case .artist(let artist): artist.id
        case .album(let album): album.id
        case .track(let track): track.id
        case .playlist(let playlist): playlist.id
        case .other(let uri, let kind, _, _, _): kind.map { MediaID($0, uri) }
        }
    }

    public var name: String {
        switch self {
        case .artist(let artist): artist.name
        case .album(let album): album.title
        case .track(let track): track.title
        case .playlist(let playlist): playlist.name
        case .other(_, _, let name, _, _): name
        }
    }

    /// The row's second line: the artist for tracks and albums, else the kind.
    public var subtitle: String {
        switch self {
        case .artist: "Artist"
        case .album(let album): album.artistName ?? "Album"
        case .track(let track): track.artistName
        case .playlist: "Playlist"
        case .other(_, let kind, _, let subtitle, _):
            subtitle ?? kind.map { $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst() } ?? ""
        }
    }

    public var kind: MediaKind? {
        switch self {
        case .artist: .artist
        case .album: .album
        case .track: .track
        case .playlist: .playlist
        case .other(_, let kind, _, _, _): kind
        }
    }

    public var artwork: ArtworkRef? {
        switch self {
        case .artist(let artist): artist.artwork
        case .album(let album): album.artwork
        case .track(let track): track.artwork
        case .playlist(let playlist): playlist.artwork
        case .other(_, _, _, _, let artwork): artwork
        }
    }

    /// Only a slim mapping: `resolve(_:)` it before favoriting.
    public var isMapping: Bool {
        if case .other = self { return true }
        return false
    }
}
