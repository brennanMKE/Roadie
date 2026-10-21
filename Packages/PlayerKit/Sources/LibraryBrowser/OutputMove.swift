import MusicBackendKit

/// What a user's Output menu choice does with what plays (#0117).
public enum OutputMove: Equatable, Sendable {
    /// Nothing to move: only where the next play goes.
    case select
    /// Music Assistant moves the queue; `autoPlay == false` keeps a paused queue paused.
    case transfer(autoPlay: Bool)
    /// AudioCore's own queue plays on This Mac; it can't move to a speaker.
    case keepLocal

    public static let localStaysText = "Local files keep playing on This Mac."

    public static func decide(
        from source: OutputDevice.ID, to target: OutputDevice.ID, sourceState: NowPlaying.State,
        thisMacFeed: ThisMacFeed
    ) -> OutputMove {
        guard source != target else { return .select }
        switch sourceState {
        case .stopped: return .select
        case .playing, .loading, .paused:
            if source == OutputDevice.thisMacID, thisMacFeed == .local { return .keepLocal }
            return .transfer(autoPlay: sourceState != .paused)
        }
    }
}
