import AudioCore
import Foundation

/// The `TrackResolver` the app hands to `Player`: files pass through, Plex tracks come from the cache.
/// The player's look-ahead resolve of the next track is the prefetch, and its cancel is the cancel.
public struct PlexTrackResolver: TrackResolver, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let cache: TrackCache
    private let savedMachineIdentifier: @Sendable () -> String?

    public init(cache: TrackCache, savedMachineIdentifier: @escaping @Sendable () -> String?) {
        self.cache = cache
        self.savedMachineIdentifier = savedMachineIdentifier
    }

    public var description: String { "PlexTrackResolver" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// A Plex track that is not cached yet resolves to the download in flight, so the player starts after a
    /// short preroll instead of after the whole file. Everything else resolves as `localURL(for:)` does.
    public func resolve(_ track: Track) async throws -> ResolvedAudio {
        switch track.source {
        case .file(let url):
            return .file(url)
        case .plex(let partKey, let cacheKey, let size):
            if let saved = savedMachineIdentifier(), saved != PlexCacheKey.machineIdentifier(of: cacheKey) {
                throw TrackCacheError.serverMismatch
            }
            switch try await cache.open(forKey: cacheKey, partKey: partKey, expectedSize: size) {
            case .ready(let url): return .file(url)
            case .downloading(let download): return .progressive(download)
            }
        }
    }

    public func localURL(for track: Track) async throws -> URL {
        switch track.source {
        case .file(let url):
            return url
        case .plex(let partKey, let cacheKey, let size):
            // The saved library was reset when the server changed; this track belongs to the old one.
            if let saved = savedMachineIdentifier(), saved != PlexCacheKey.machineIdentifier(of: cacheKey) {
                throw TrackCacheError.serverMismatch
            }
            return try await cache.file(forKey: cacheKey, partKey: partKey, expectedSize: size)
        }
    }
}
