import Foundation

public enum TimeMode: String, Sendable, Codable { case elapsed, remaining }

/// The four 7-segment digits Winamp shows; nil = blank (Webamp getTimeObj(null)).
public struct TimeDigits: Equatable, Sendable {
    public var minutesTens: Int?
    public var minutesOnes: Int?
    public var secondsTens: Int?
    public var secondsOnes: Int?

    public static let blank = TimeDigits(minutesTens: nil, minutesOnes: nil, secondsTens: nil, secondsOnes: nil)

    public init(minutesTens: Int?, minutesOnes: Int?, secondsTens: Int?, secondsOnes: Int?) {
        self.minutesTens = minutesTens
        self.minutesOnes = minutesOnes
        self.secondsTens = secondsTens
        self.secondsOnes = secondsOnes
    }

    /// Floors like Webamp's getTimeObj; clamps to 0...5999 s so 99:59 is the largest value.
    public init(seconds: TimeInterval) {
        let whole = seconds.isFinite ? min(max(Int(seconds.rounded(.down)), 0), 5999) : 0
        let minutes = whole / 60
        let rest = whole % 60
        self.init(minutesTens: minutes / 10, minutesOnes: minutes % 10, secondsTens: rest / 10, secondsOnes: rest % 10)
    }

    /// elapsed, or max(duration - elapsed, 0) in remaining mode.
    public static func shown(mode: TimeMode, elapsed: TimeInterval, duration: TimeInterval) -> TimeDigits {
        switch mode {
        case .elapsed: TimeDigits(seconds: elapsed)
        case .remaining: TimeDigits(seconds: max(duration - elapsed, 0))
        }
    }
}
