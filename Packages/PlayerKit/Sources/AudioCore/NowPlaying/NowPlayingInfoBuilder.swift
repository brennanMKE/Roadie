import Foundation
import MediaPlayer

/// Pure mapping from a snapshot to the `MPNowPlayingInfoCenter` dictionary.
/// Artwork is merged in by the bridge so this stays free of `MPMediaItemArtwork`.
public enum NowPlayingInfoBuilder {
    public static func info(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyPlaybackDuration: Double(snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(snapshot.elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = snapshot.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        return info
    }
}
