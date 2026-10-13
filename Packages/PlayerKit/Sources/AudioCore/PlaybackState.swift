public enum PlaybackState: Sendable {
    case stopped
    /// A track is selected and its resolve/open is in flight; nothing is scheduled and the position is 0.
    /// The pending play-or-park intent is kept by the player.
    case loading
    case playing
    case paused
}
