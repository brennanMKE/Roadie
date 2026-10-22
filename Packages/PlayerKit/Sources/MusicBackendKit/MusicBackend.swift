import Foundation

public struct BackendCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let search = BackendCapabilities(rawValue: 1 << 0)
    public static let playlists = BackendCapabilities(rawValue: 1 << 1)
    public static let artwork = BackendCapabilities(rawValue: 1 << 2)
    /// Can play through "This Mac" (AudioCore).
    public static let localOutput = BackendCapabilities(rawValue: 1 << 3)
    /// Controls players other than this Mac.
    public static let remoteOutputs = BackendCapabilities(rawValue: 1 << 4)
    /// Has the server's automatic rows (Discover, #0143).
    public static let recommendations = BackendCapabilities(rawValue: 1 << 7)
    /// Favorites: `setFavorite` and `favoriteCurrentTrack` (#0141).
    public static let favorites = BackendCapabilities(rawValue: 1 << 6)
    /// Create, rename and delete playlists and add tracks to them (#0135, #0136).
    public static let playlistEditing = BackendCapabilities(rawValue: 1 << 5)
}

/// No case carries a URL, a request, a header or a token; `errorDescription` is user-facing.
public enum MusicBackendError: Error, Hashable, Sendable, LocalizedError {
    /// What to do, e.g. "Add a Music Assistant server under Settings › Music Assistant."
    case notConfigured(String)
    /// A library call before `connect()`.
    case notConnected
    /// The backend's own message.
    case unreachable(String)
    case unauthorized
    case notFound(MediaID)
    case unsupported(BackendCapabilities)
    case unknownOutput(OutputDevice.ID)
    /// Anything else, its localized description.
    case backend(String)
    /// The server refused for want of permission (a token scope); the server's message (#0135).
    case forbidden(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message), .unreachable(let message), .backend(let message), .forbidden(let message):
            message
        case .notConnected: "Not connected to the music source."
        case .unauthorized: "The music source rejected the sign-in."
        case .notFound(let id): "Could not find \(id.kind.rawValue) \(id.rawValue)."
        case .unsupported: "This music source does not support that."
        case .unknownOutput: "That output is not available."
        }
    }
}

public protocol MusicBackend: AnyObject, Sendable {
    /// "musicAssistant", "folder": the key Settings and logs use.
    var sourceID: String { get }
    var displayName: String { get }
    var capabilities: BackendCapabilities { get }

    /// Reads settings, reaches the server, picks the library. Idempotent; throws `MusicBackendError`.
    func connect() async throws
    func disconnect() async

    func artists(page: PageRequest) async throws -> Page<LibraryArtist>
    /// `artist == nil` lists every album.
    func albums(of artist: MediaID?, page: PageRequest) async throws -> Page<LibraryAlbum>
    func tracks(of album: MediaID) async throws -> [LibraryTrack]
    func playlists(page: PageRequest) async throws -> Page<LibraryPlaylist>
    func tracks(ofPlaylist playlist: MediaID) async throws -> [LibraryTrack]
    func search(_ query: String, limit: Int) async throws -> SearchResults
    /// Bytes of an image no larger than `maxPixels` on its long side.
    func artwork(_ ref: ArtworkRef, maxPixels: Int) async throws -> Data

    func outputs() async throws -> [OutputDevice]
    /// Album and playlist ids expand to their tracks, in order.
    func play(_ items: [MediaID], on output: OutputDevice.ID, mode: PlayMode) async throws
    func transport(_ command: TransportCommand, on output: OutputDevice.ID) async throws
    /// Moves the source output's queue, position included, to the target and stops the source.
    /// `autoPlay == false` leaves it paused on the target.
    func transfer(from source: OutputDevice.ID, to target: OutputDevice.ID, autoPlay: Bool) async throws
    /// Syncs `adding` to `leader` and unsyncs `removing` (#0118). Default: `.unsupported(.remoteOutputs)`.
    func setGroupMembers(of leader: OutputDevice.ID, adding: [OutputDevice.ID], removing: [OutputDevice.ID]) async throws
    /// Yields the current snapshot at once, then one per change. Ends when the subscriber cancels.
    func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying>

    /// Discover rows (#0143), in the server's order. Default: `.unsupported(.recommendations)`.
    func recommendationRows() async throws -> [RecommendationRow]
    func recommendationItems(_ row: RecommendationRow) async throws -> [RecommendationItem]
    /// A slim item (`.other`) as the full one when the backend can find it. Default: the item itself.
    func resolve(_ item: RecommendationItem) async throws -> RecommendationItem
    /// The queue playing on `output` (#0144): a snapshot at once, then one per change. Default: one empty snapshot.
    func queue(on output: OutputDevice.ID) async -> AsyncStream<RemoteQueueSnapshot>
    /// Changes the queue playing on `output` (#0144). Default: `.unsupported(.queueEditing)`.
    func edit(_ edit: QueueEdit, on output: OutputDevice.ID) async throws
    /// Saves the queue playing on `output` as a new playlist named `name` (#0140). Default: `.unsupported(.queueEditing)`.
    func saveQueueAsPlaylist(on output: OutputDevice.ID, named name: String) async throws
    /// Favorites or unfavorites a track, album, artist or playlist (#0141). Default: `.unsupported(.favorites)`.
    func setFavorite(_ id: MediaID, _ on: Bool) async throws
    /// Favorites what `output` plays now (#0141). Default: `.unsupported(.favorites)`.
    func favoriteCurrentTrack(on output: OutputDevice.ID) async throws
    /// Library changes made elsewhere (#0139), as refetch hints. Default: a stream that finishes at once.
    func libraryChanges() async -> AsyncStream<LibraryChange>
    /// How many items of `kind` are favorited (#0142); nil when unknown. Default: `.unsupported(.favorites)`.
    func favoriteCount(_ kind: MediaKind) async throws -> Int?
    /// Favorited items, paged (#0142). Defaults: `.unsupported(.favorites)`.
    func favoriteTracks(page: PageRequest) async throws -> Page<LibraryTrack>
    func favoriteAlbums(page: PageRequest) async throws -> Page<LibraryAlbum>
    func favoriteArtists(page: PageRequest) async throws -> Page<LibraryArtist>
    func favoritePlaylists(page: PageRequest) async throws -> Page<LibraryPlaylist>
    /// Radio (#0147); the defaults throw `.unsupported`.
    func radios(page: PageRequest) async throws -> Page<LibraryRadio>
    func addRadio(url: String, name: String) async throws -> LibraryRadio
    func favoriteRadios(page: PageRequest) async throws -> Page<LibraryRadio>
    // Playlist editing (#0135, #0136); defaults in MusicBackend+Playlists.swift throw `.unsupported(.playlistEditing)`.
    func createPlaylist(named name: String) async throws -> LibraryPlaylist
    func renamePlaylist(_ id: MediaID, to name: String) async throws
    func deletePlaylist(_ id: MediaID) async throws
    /// Tracks and albums (albums expand server-side), appended in order (#0136).
    func add(_ items: [MediaID], toPlaylist id: MediaID) async throws
    /// The playlist as M3U8 text; its entries are the server's paths and URIs (#0148).
    func exportPlaylist(_ id: MediaID) async throws -> String
    /// Creates a playlist from M3U8 text, matching its entries to the library (#0148).
    func importPlaylist(m3u: String) async throws -> LibraryPlaylist
    /// Removes the tracks at 1-based `positions` (#0138).
    func remove(positions: [Int], fromPlaylist id: MediaID) async throws
    /// Moves the track at 1-based `from` to `to` (#0138); `.unsupported` when the server can't reorder.
    func movePlaylistTrack(_ id: MediaID, from: Int, to: Int) async throws
}

extension MusicBackend {
    public func recommendationRows() async throws -> [RecommendationRow] {
        throw MusicBackendError.unsupported(.recommendations)
    }

    public func recommendationItems(_ row: RecommendationRow) async throws -> [RecommendationItem] {
        throw MusicBackendError.unsupported(.recommendations)
    }

    public func resolve(_ item: RecommendationItem) async throws -> RecommendationItem { item }
}

extension MusicBackend {
    /// Backends without change events have nothing to follow.
    public func libraryChanges() async -> AsyncStream<LibraryChange> {
        AsyncStream { $0.finish() }
    }

    /// Backends without remote outputs can't move a queue.
    public func transfer(from source: OutputDevice.ID, to target: OutputDevice.ID, autoPlay: Bool) async throws {
        throw MusicBackendError.unsupported(.remoteOutputs)
    }

    /// Backends without remote outputs can't group players.
    public func setGroupMembers(
        of leader: OutputDevice.ID, adding: [OutputDevice.ID], removing: [OutputDevice.ID]
    ) async throws {
        throw MusicBackendError.unsupported(.remoteOutputs)
    }

    /// Backends without favorites refuse.
    public func setFavorite(_ id: MediaID, _ on: Bool) async throws {
        throw MusicBackendError.unsupported(.favorites)
    }

    /// Backends without favorites refuse.
    public func favoriteCurrentTrack(on output: OutputDevice.ID) async throws {
        throw MusicBackendError.unsupported(.favorites)
    }
}
