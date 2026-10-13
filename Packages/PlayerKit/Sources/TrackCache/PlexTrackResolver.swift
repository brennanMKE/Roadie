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
