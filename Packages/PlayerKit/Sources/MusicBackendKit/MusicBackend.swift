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
}

/// No case carries a URL, a request, a header or a token; `errorDescription` is user-facing.
public enum MusicBackendError: Error, Hashable, Sendable, LocalizedError {
    /// What to do, e.g. "Add the Plex server address and sign in under Settings > Plex."
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
    /// "plex", "musicAssistant", "folder": the key Settings and logs use.
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
    /// Yields the current snapshot at once, then one per change. Ends when the subscriber cancels.
    func nowPlaying(on output: OutputDevice.ID) async -> AsyncStream<NowPlaying>
}
