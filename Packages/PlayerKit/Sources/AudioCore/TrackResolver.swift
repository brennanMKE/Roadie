import Foundation

/// What a resolver hands the player: a complete file, or a source whose bytes are still arriving.
public enum ResolvedAudio: Sendable {
    case file(URL)
    case progressive(any ProgressiveByteSource)
}

/// Maps a track to a local file. TrackCache plugs in here at M2.
public protocol TrackResolver: Sendable {
    func localURL(for track: Track) async throws -> URL
    /// The file, or a progressive source when the bytes are still downloading. The default is
    /// `.file(localURL(for:))`; TrackCache overrides it for Plex tracks that are not cached yet.
    func resolve(_ track: Track) async throws -> ResolvedAudio
}

extension TrackResolver {
    public func resolve(_ track: Track) async throws -> ResolvedAudio {
        .file(try await localURL(for: track))
    }
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
