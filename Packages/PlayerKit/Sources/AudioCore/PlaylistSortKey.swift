import Foundation

/// Sort keys for the playlist's Sort List menu. A track that isn't a local file falls back to its title.
public enum PlaylistSortKey {
    public static func fileName(_ track: Track) -> String {
        if case .file(let url) = track.source { return url.lastPathComponent }
        return track.title
    }

    public static func path(_ track: Track) -> String {
        if case .file(let url) = track.source { return url.path }
        return track.title
    }
}
