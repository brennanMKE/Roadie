import Foundation
import MusicBackendKit

/// Builds a `NowPlaying` from a player and its active queue. Pure: every input, the clock included, is a parameter.
///
/// No event and no playing player has been recorded yet (#0076), so every field is read leniently and each has a
/// fallback: the player's `current_media` first, then the queue's `current_item`.
public enum MANowPlayingMapper {
    /// `skew` is server time minus local time (`time` command minus `Date()`), in seconds.
    public static func snapshot(
        output: OutputDevice.ID, player: MAPlayer?, queue: MAPlayerQueue?, skew: Double, now: Date
    ) -> NowPlaying {
        let media = player?.currentMedia
        let queueItem = queue?.currentItem
        let mediaItem = queueItem?.mediaItem

        var snapshot = NowPlaying(output: output, state: state(player: player, queue: queue), updatedAt: now)
        snapshot.title = nonEmpty(media?.title) ?? nonEmpty(mediaItem?["name"]?.stringValue) ?? nonEmpty(queueItem?.name)
        snapshot.artist =
            nonEmpty(media?.artist) ?? nonEmpty(mediaItem?["artists"]?[0]?["name"]?.stringValue)
        snapshot.album = nonEmpty(media?.album) ?? nonEmpty(mediaItem?["album"]?["name"]?.stringValue)
        snapshot.duration = positive(media?.duration) ?? positive(queueItem?.duration)
            ?? positive(mediaItem?["duration"]?.doubleValue)
        if let uri = media?.uri ?? mediaItem?["uri"]?.stringValue, MAURI.parse(uri)?.mediaType == .track {
            snapshot.item = MediaID(.track, uri)
        }

        var timing: (elapsed: Double, updated: Double?)?
        if let elapsed = queue?.elapsedTime {
            timing = (elapsed, queue?.elapsedTimeLastUpdated)
        } else if let elapsed = media?.elapsedTime {
            timing = (elapsed, media?.elapsedTimeLastUpdated)
        } else if let elapsed = player?.elapsedTime {
            timing = (elapsed, player?.elapsedTimeLastUpdated)
        }
        if let timing {
            snapshot.elapsed = max(0, timing.elapsed)
            snapshot.updatedAt = localDate(serverTime: timing.updated, skew: skew, now: now)
        }

        snapshot.volume = player?.volumeLevel.map { Float(min(max($0, 0), 100) / 100) }
        snapshot.artwork = proxyID(imageURL: media?.imageURL).map { ArtworkRef($0) }
            ?? nonEmpty(queueItem?.image?.proxyID).map { ArtworkRef($0) }
        return snapshot
    }

    static func state(player: MAPlayer?, queue: MAPlayerQueue?) -> NowPlaying.State {
        switch player?.state {
        case .playing: return .playing
        case .paused: return .paused
        case .idle: return .stopped
        case .unknown, nil:
            switch MAPlaybackState(queue?.state) {
            case .playing: return .playing
            case .paused: return .paused
            case .idle, .unknown: return .stopped
            }
        }
    }

    /// A server timestamp as a local date; `now` when it is missing or implausible (over a minute ahead, a day behind).
    static func localDate(serverTime: Double?, skew: Double, now: Date) -> Date {
        guard let serverTime, serverTime.isFinite else { return now }
        let date = Date(timeIntervalSince1970: serverTime - skew)
        let offset = date.timeIntervalSince(now)
        if offset > 60 || offset < -86_400 { return now }
        return date
    }

    /// `<base>/imageproxy/<proxy_id>?size=...`: the proxy id; the host is the server's own and ignored.
    static func proxyID(imageURL: String?) -> String? {
        guard let imageURL, let url = URL(string: imageURL) else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "imageproxy"), parts.indices.contains(index + 1) else { return nil }
        return nonEmpty(parts[index + 1])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

/// What one pushed event means for one player's now-playing. Events are hints (#0076): anything that matches the
/// player but does not decode asks for a refetch instead.
public enum MAEventMatch {
    public enum Action: Hashable, Sendable {
        case player(MAPlayer)
        case queue(MAPlayerQueue)
        case elapsed(Double)
        case refetch
        case ignore
    }

    public static func classify(_ event: MAServerEvent, playerID: String, queueID: String) -> Action {
        let name = event.event
        guard name.hasPrefix("player_") || name.hasPrefix("queue_") else { return .ignore }
        let target = event.objectID ?? event.data["player_id"]?.stringValue ?? event.data["queue_id"]?.stringValue
        guard let target else { return .refetch }
        guard target == playerID || target == queueID else { return .ignore }
        switch name {
        case "player_updated":
            return (try? event.data.decode(as: MAPlayer.self)).map(Action.player) ?? .refetch
        case "queue_updated":
            return (try? event.data.decode(as: MAPlayerQueue.self)).map(Action.queue) ?? .refetch
        case "queue_time_updated":
            if let seconds = event.data.doubleValue ?? event.data["elapsed_time"]?.doubleValue { return .elapsed(seconds) }
            return .refetch
        default:
            // player_added/removed, queue_added, queue_items_updated, player_config_updated.
            return .refetch
        }
    }
}

/// How often a now-playing watcher asks the server when events do not (or do) arrive.
public struct MANowPlayingPolicy: Hashable, Sendable {
    /// Until the first event applies: external changes show within about a second even if no event decodes.
    public var eagerPoll: Duration
    /// Once events are known to work: a cheap safety net.
    public var relaxedPoll: Duration
    /// Several unreadable events in a burst cost one refetch.
    public var refetchDebounce: Duration

    public init(
        eagerPoll: Duration = .seconds(1), relaxedPoll: Duration = .seconds(10),
        refetchDebounce: Duration = .milliseconds(150)
    ) {
        self.eagerPoll = eagerPoll
        self.relaxedPoll = relaxedPoll
        self.refetchDebounce = refetchDebounce
    }

    public static let standard = MANowPlayingPolicy()
}
