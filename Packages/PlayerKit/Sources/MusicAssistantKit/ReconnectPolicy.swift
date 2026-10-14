import Foundation

/// How long to wait before reconnect attempt n (1-based). Pure; tests pass `jitter: 0`.
public struct ReconnectPolicy: Hashable, Sendable {
    public var steps: [Duration]
    public var cap: Duration
    /// +/- fraction of the delay, e.g. 0.2 for 20 %.
    public var jitter: Double

    public init(steps: [Duration], cap: Duration, jitter: Double) {
        self.steps = steps
        self.cap = cap
        self.jitter = jitter
    }

    public static let `default` = ReconnectPolicy(
        steps: [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)], cap: .seconds(30), jitter: 0.2)

    public func delay(attempt: Int, using generator: inout some RandomNumberGenerator) -> Duration {
        let base = attempt >= 1 && attempt <= steps.count ? steps[attempt - 1] : cap
        let seconds = min(Self.seconds(base), Self.seconds(cap))
        guard jitter > 0 else { return .seconds(seconds) }
        let factor = 1 + Double.random(in: -jitter...jitter, using: &generator)
        return .seconds(seconds * factor)
    }

    public func delay(attempt: Int) -> Duration {
        var generator = SystemRandomNumberGenerator()
        return delay(attempt: attempt, using: &generator)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
