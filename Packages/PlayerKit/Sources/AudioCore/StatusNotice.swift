import Foundation

/// A short message that takes over the marquee for a few seconds: Webamp's `userInput.userMessage`,
/// the first thing `getMarqueeText` returns. A value with explicit times so it is testable without timers.
public struct StatusNotice: Equatable, Sendable {
    /// How long a notice stays up before the marquee goes back to the track.
    public static let duration: Duration = .seconds(3)

    /// What the marquee shows. Short enough to sit still (31 UTF-16 units or fewer) wherever possible.
    public let text: String
    /// A longer hint for places with room (the no-skin placeholder), nil when `text` is all there is.
    public let detail: String?
    public let shownAt: ContinuousClock.Instant

    public init(text: String, detail: String? = nil, shownAt: ContinuousClock.Instant = .now) {
        self.text = text
        self.detail = detail
        self.shownAt = shownAt
    }

    public var expiresAt: ContinuousClock.Instant { shownAt + Self.duration }

    public func isActive(at now: ContinuousClock.Instant) -> Bool { now < expiresAt }

    /// "Skipped 1 file", "Skipped 3 files", "Skipped 1 of 5 files" (when some tracks loaded);
    /// nil when nothing was skipped. `detail` is "see Console" (the loader logs each file and reason).
    public static func skipped(_ result: LocalImport, shownAt: ContinuousClock.Instant = .now) -> StatusNotice? {
        let n = result.skipped.count
        guard n > 0 else { return nil }
        let total = n + result.tracks.count
        let files = total == 1 ? "file" : "files"
        let text = result.tracks.isEmpty ? "Skipped \(n) \(files)" : "Skipped \(n) of \(total) \(files)"
        return StatusNotice(text: text, detail: "see Console", shownAt: shownAt)
    }

    /// "Could not load <name>" for a skin that failed to parse; `name` is the file name without extension.
    public static func skinFailed(_ name: String, shownAt: ContinuousClock.Instant = .now) -> StatusNotice {
        StatusNotice(text: "Could not load \(name)", shownAt: shownAt)
    }

    /// "Could not play <title>", or "Could not play 3 tracks" when a run of failures ended in a stop.
    /// The error text is `detail` only: it is shown where there is room (the placeholder) and logged,
    /// never scrolled through the marquee.
    public static func playbackFailed(_ failure: PlaybackFailure, shownAt: ContinuousClock.Instant = .now) -> StatusNotice {
        let text = !failure.skipped && failure.consecutiveFailures > 1
            ? "Could not play \(failure.consecutiveFailures) tracks"
            : "Could not play \(failure.track?.title ?? "this track")"
        return StatusNotice(text: text, detail: failure.message, shownAt: shownAt)
    }
}
