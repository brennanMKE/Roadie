import Foundation

/// What the system should show right now. Plain data so the mapping stays unit-testable.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var state: PlaybackState

    public init(
        title: String, artist: String, album: String? = nil,
        duration: TimeInterval, elapsed: TimeInterval, state: PlaybackState
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.state = state
    }
}

extension PlaybackState: Equatable {}
