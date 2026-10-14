import AudioCore
import Foundation
import PlexKit

public enum PlexCacheKey {
    /// "<machineIdentifier>-<part.id>-<part.keyStamp ?? 0>". The stamp is the change marker Plex puts
    /// in the part key, so a re-encoded file gets a new key and the old file ages out. The server id
    /// is reduced to letters and digits, so a key can never contain a path separator.
    public static func key(machineIdentifier: String, part: PlexPart) -> String {
        let server = String(machineIdentifier.unicodeScalars.filter {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }.map(Character.init))
        return "\(server)-\(part.id)-\(part.keyStamp ?? 0)"
    }

    /// The machineIdentifier prefix of a key (everything before the first "-").
    public static func machineIdentifier(of key: String) -> String {
        String(key.prefix { $0 != "-" })
    }
}

extension Track {
    /// title, artist = grandparentTitle, album = parentTitle, duration, bitrate and channels from
    /// the first media (the audio stream fills gaps), sampleRate from the audio stream when the
    /// server sends one, source = `.plex`. Throws
    /// `.notPlexTrack` when the track has no part.
    public init(plexTrack: PlexTrack, machineIdentifier: String) throws {
        guard let part = plexTrack.primaryPart else { throw TrackCacheError.notPlexTrack }
        let media = plexTrack.media.first
        let duration = plexTrack.durationSeconds ?? part.duration.map { Double($0) / 1000 } ?? 0
        self.init(
            title: plexTrack.title,
            artist: plexTrack.grandparentTitle ?? "",
            album: plexTrack.parentTitle,
            duration: duration,
            bitrate: media?.bitrate ?? plexTrack.audioStream?.bitrate,
            sampleRate: plexTrack.audioStream?.samplingRate.map(Double.init),
            channels: media?.audioChannels ?? plexTrack.audioStream?.channels,
            source: .plex(
                partKey: part.key,
                cacheKey: PlexCacheKey.key(machineIdentifier: machineIdentifier, part: part),
                size: part.size.map(Int64.init)))
    }
}
