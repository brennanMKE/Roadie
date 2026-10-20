import Foundation

/// What a resolver hands the player: a complete file, or a source whose bytes are still arriving.
public enum ResolvedAudio: Sendable {
    case file(URL)
    case progressive(any ProgressiveByteSource)
}

/// Maps a track to a local file. A backend's resolver plugs in here.
public protocol TrackResolver: Sendable {
    func localURL(for track: Track) async throws -> URL
    /// The file, or a progressive source when the bytes are still downloading. The default is
    /// `.file(localURL(for:))`; a resolver whose bytes are still arriving returns `.progressive`.
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
        }
    }
}
