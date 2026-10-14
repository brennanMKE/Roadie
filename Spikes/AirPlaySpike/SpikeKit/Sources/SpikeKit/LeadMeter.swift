import Foundation

/// How far ahead of the clock the pipeline has requested media: last enqueued (or tap-processed) PTS minus the
/// current time. On a local route this stays at a few seconds; on AirPlay 2 with enhanced buffering, minutes.
public struct LeadMeter: Sendable {
    public enum Classification: String, Sendable { case seconds, between, minutes }

    private var samples: [(at: ContinuousClock.Instant, lead: TimeInterval)] = []
    public private(set) var current: TimeInterval = 0
    public private(set) var max: TimeInterval = 0

    public init() {}

    public mutating func record(lastEnqueued: TimeInterval, now: TimeInterval, at instant: ContinuousClock.Instant) {
        let lead = lastEnqueued - now
        current = lead
        if samples.isEmpty || lead > max { max = lead }
        samples.append((instant, lead))
        // Keep the last five minutes, enough for any window the UI asks about.
        let cutoff = instant.advanced(by: .seconds(-300))
        samples.removeAll { $0.at < cutoff }
    }

    /// Largest lead among samples no older than `seconds` before `asOf` (default: the newest sample).
    public func maxInLast(seconds: Double, asOf: ContinuousClock.Instant? = nil) -> TimeInterval? {
        guard let newest = samples.last?.at else { return nil }
        let ref = asOf ?? newest
        let cutoff = ref.advanced(by: .seconds(-seconds))
        return samples.filter { $0.at >= cutoff }.map(\.lead).max()
    }

    /// Classifies the recent maximum: up to 10 s is a local-style buffer, 30 s or more is enhanced buffering.
    public var classification: Classification? {
        guard let recent = maxInLast(seconds: 60) else { return nil }
        if recent <= 10 { return .seconds }
        if recent >= 30 { return .minutes }
        return .between
    }
}
