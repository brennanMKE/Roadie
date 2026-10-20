import AudioCore
import Foundation
import MusicBackendKit

/// An AudioCore `Track` plus the library id it came from (nil for a plain local file).
public struct LocalQueueItem: Hashable, Sendable {
    public var track: Track
    public var id: MediaID?

    public init(track: Track, id: MediaID?) {
        self.track = track
        self.id = id
    }
}

/// `AudioCore.Player` as the "This Mac" output: queue, transport and the now-playing stream.
/// Backends that play through AudioCore (the folder; Music Assistant with #0066) hand it tracks; it knows nothing about them.
@MainActor
public final class LocalPlayerOutput {
    public let player: Player
    public nonisolated static let device = OutputDevice.thisMac

    /// Library ids of queued tracks, keyed by the queue entry's id.
    private var ids: [UUID: MediaID] = [:]

    private struct Subscription {
        var token: PlayerEventToken
        var continuation: AsyncStream<NowPlaying>.Continuation
    }

    private var subscriptions: [UUID: Subscription] = [:]

    /// Live now-playing subscriptions (tests).
    public var subscriberCount: Int { subscriptions.count }

    /// The equalizer is a property of this Mac's audio graph; this passes through to the player.
    public var eq: EQState {
        get { player.eq }
        set { player.eq = newValue }
    }

    public init(player: Player) {
        self.player = player
    }

    /// `.replace`: clear the queue, enqueue, play from `startIndex` (clamped). `.append`: enqueue, and start
    /// playing the first new track only if the player was stopped with an empty queue.
    public func play(_ items: [LocalQueueItem], mode: PlayMode) {
        let wasIdle = player.state == .stopped && player.queue.tracks.isEmpty
        switch mode {
        case .replace(let startIndex):
            player.clearQueue()
            ids.removeAll()
            guard !items.isEmpty else { return }
            register(items)
            player.enqueue(items.map(\.track))
            player.play(at: min(max(startIndex, 0), items.count - 1))
        case .append:
            guard !items.isEmpty else { return }
            let first = player.queue.tracks.count
            register(items)
            player.enqueue(items.map(\.track))
            if wasIdle { player.play(at: first) }
        }
        prune()
    }

    /// The queue as it is now (tracks, their library ids, index, repeat, shuffle).
    public func queueSnapshot() -> QueueSnapshot {
        QueueSnapshot(
            items: player.queue.tracks.map { LocalQueueItem(track: $0, id: ids[$0.id]) },
            currentIndex: player.queue.currentIndex,
            repeatMode: player.repeatMode,
            isShuffled: player.isShuffled)
    }

    /// Fills an empty, stopped player from `snapshot` without starting anything; false (no change) otherwise.
    @discardableResult
    public func restore(_ snapshot: QueueSnapshot) -> Bool {
        let restored = player.restoreQueue(
            snapshot.items.map(\.track), currentIndex: snapshot.currentIndex,
            repeatMode: snapshot.repeatMode, isShuffled: snapshot.isShuffled)
        if restored { register(snapshot.items) }
        return restored
    }

    public func perform(_ command: TransportCommand) {
        switch command {
        case .play: player.play()
        case .pause: player.pause()
        case .togglePlayPause: player.togglePause()
        case .stop: player.stop()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let seconds): player.seek(to: seconds)
        case .setVolume(let volume):
            player.volume = volume
            for subscription in subscriptions.values { subscription.continuation.yield(snapshot()) }
        case .setBalance(let balance): player.balance = balance
        case .setShuffle(let on): player.isShuffled = on
        case .setRepeat(let on): player.repeatMode = on ? .all : .off
        }
    }

    public func snapshot(at date: Date = Date()) -> NowPlaying {
        let current = player.queue.current
        let state: NowPlaying.State = switch player.state {
        case .stopped: .stopped
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        }
        return NowPlaying(
            output: Self.device.id,
            state: state,
            item: current.flatMap { ids[$0.id] },
            title: current?.title,
            artist: current?.artist,
            album: current?.album,
            duration: current?.duration,
            elapsed: player.currentTime,
            updatedAt: date,
            volume: player.volume)
    }

    /// The current snapshot at once, then one per player event and per volume change.
    public func nowPlaying() -> AsyncStream<NowPlaying> {
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlaying.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let token = player.addEventObserver { [weak self] _ in
            guard let self else { return }
            continuation.yield(self.snapshot())
        }
        subscriptions[id] = Subscription(token: token, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.endSubscription(id) }
        }
        continuation.yield(snapshot())
        return stream
    }

    private func endSubscription(_ id: UUID) {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        player.removeEventObserver(subscription.token)
    }

    private func register(_ items: [LocalQueueItem]) {
        for item in items {
            if let id = item.id { ids[item.track.id] = id }
        }
    }

    private func prune() {
        let live = Set(player.queue.tracks.map(\.id))
        ids = ids.filter { live.contains($0.key) }
    }
}
