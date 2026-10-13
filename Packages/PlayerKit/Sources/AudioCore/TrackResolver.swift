import Foundation

/// Maps a track to a local file. TrackCache plugs in here at M2.
public protocol TrackResolver: Sendable {
    func localURL(for track: Track) async throws -> URL
}

public struct FileTrackResolver: TrackResolver {
    public init() {}

    public func localURL(for track: Track) async throws -> URL {
        switch track.source {
        case .file(let url): url
        case .plex: throw AudioCoreError.unresolvableSource(track.source)
        }
    }
}
