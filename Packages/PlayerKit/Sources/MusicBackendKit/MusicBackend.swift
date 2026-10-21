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

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message), .unreachable(let message), .backend(let message): message
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
}
