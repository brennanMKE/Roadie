import AudioCore
import Foundation

/// Keeps the current track and the one the queue will play next pinned in the cache, so eviction
/// never removes them and their downloads are not cancelled while nobody waits.
@MainActor
public final class CachePinner {
    private let cache: TrackCache
    private let player: Player
    private var token: PlayerEventToken?
    private var lastKeys: Set<String>?
    private var pending: Task<Void, Never>?

    public init(cache: TrackCache, player: Player) {
        self.cache = cache
        self.player = player
    }

    /// Registers a Player event observer and pins now.
    public func install() {
        guard token == nil else { return }
        token = player.addEventObserver { [weak self] _ in self?.update() }
        update()
    }

    /// Removes the observer and pins the empty set.
    public func uninstall() {
        guard let token else { return }
        player.removeEventObserver(token)
        self.token = nil
        apply([])
    }

    /// The plex cache keys of the current track and of the track that follows it.
    public static func pinnedKeys(in queue: PlayQueue) -> Set<String> {
        var indices: [Int] = []
        if let current = queue.currentIndex { indices.append(current) }
        if let next = queue.indexAfterCurrentEnds() { indices.append(next) }
        var keys: Set<String> = []
        for index in indices {
            if case .plex(_, let cacheKey, _) = queue.tracks[index].source { keys.insert(cacheKey) }
        }
        return keys
    }

    private func update() {
        apply(Self.pinnedKeys(in: player.queue))
    }

    /// Calls are chained so the cache sees the sets in the order they were computed.
    private func apply(_ keys: Set<String>) {
        guard keys != lastKeys else { return }
        lastKeys = keys
        let cache = self.cache
        let previous = pending
        pending = Task {
            await previous?.value
            await cache.setPinned(keys)
        }
    }
}
