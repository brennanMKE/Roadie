import Foundation

/// What a probe (or the Library window's own connect) found out about one source.
public enum SourceProbeOutcome: Hashable, Sendable {
    case reachable
    case notConfigured(String)
    case unreachable(String)
}

/// Why the active source is not the preferred one.
public enum FallbackReason: Hashable, Sendable {
    case notConfigured
    case unreachable(String)
}

/// When to look again at a source that is ahead of the active one.
public struct RetrySchedule: Hashable, Sendable {
    public var steps: [Duration]
    public var cap: Duration
    public var minimumSpacing: Duration

    public init(steps: [Duration], cap: Duration, minimumSpacing: Duration) {
        self.steps = steps
        self.cap = cap
        self.minimumSpacing = minimumSpacing
    }

    public static let `default` = RetrySchedule(
        steps: [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80), .seconds(160)],
        cap: .seconds(300), minimumSpacing: .seconds(5))

    /// `steps[failures - 1]`, then `cap` once the steps run out; never above `cap`. `failures` is at least 1.
    public func delay(afterFailures failures: Int) -> Duration {
        let index = max(failures, 1) - 1
        guard index < steps.count else { return cap }
        return min(steps[index], cap)
    }
}

public struct SourceHealth: Hashable, Sendable {
    /// The last result, nil until probed.
    public var outcome: SourceProbeOutcome?
    /// Consecutive failures; reset by a reachable result, a Retry and a user selection.
    public var failures = 0
    /// Engine time when the last probe ended.
    public var lastProbeEnded: Duration?
    public var isProbing = false
    public var hasTimer = false

    public init() {}
}

/// Pure: which library source is in use and when to look at the others. It takes events and a time value and
/// returns effects; the driver (`LibraryFallbackController`) does the I/O. Candidate order is the preferred
/// source, then the others in list order; a source "ahead" of the active one is a better candidate.
public struct LibraryFallbackPolicy: Hashable, Sendable {
    public enum ActivationKind: Hashable, Sendable { case user, fallback, restore }

    public enum Event: Hashable, Sendable {
        case start, userSelected(String), configuredChanged, retryRequested
        case failureReported(String), probeResult(String, SourceProbeOutcome), probeAborted(String), probeDue(String)
    }

    public enum Effect: Hashable, Sendable {
        case activate(String, ActivationKind), probe(String), schedule(String, after: Duration), cancelSchedule(String)
    }

    public let order: [String]
    public let schedule: RetrySchedule
    public private(set) var preferred: String
    public private(set) var active: String
    /// Why `active` is not `preferred`. Non-nil whenever they differ; it may also linger on the preferred source
    /// after a failed connect that had nothing to fall back to.
    public private(set) var reason: FallbackReason?
    public private(set) var health: [String: SourceHealth]

    public var candidates: [String] { [preferred] + order.filter { $0 != preferred } }

    public init(order: [String], preferred: String, schedule: RetrySchedule = .default) {
        precondition(!order.isEmpty && Set(order).count == order.count, "fallback order must be non-empty and distinct")
        precondition(order.contains(preferred), "the preferred source must be in the order")
        self.order = order
        self.schedule = schedule
        self.preferred = preferred
        active = preferred
        health = Dictionary(uniqueKeysWithValues: order.map { ($0, SourceHealth()) })
    }

    // MARK: Order helpers

    private func rank(_ id: String) -> Int { candidates.firstIndex(of: id) ?? Int.max }
    private func isAhead(_ id: String) -> Bool { rank(id) < rank(active) }

    // MARK: Events

    /// `configured` is read at the moment of the event (defaults only); `now` is any monotonic duration.
    public mutating func handle(_ event: Event, configured: (String) -> Bool, now: Duration) -> [Effect] {
        switch event {
        case .start: return start(configured: configured)
        case .userSelected(let id): return userSelected(id)
        case .configuredChanged: return configuredChanged(configured: configured, now: now)
        case .retryRequested: return retryRequested(configured: configured, now: now)
        case .failureReported(let id): return failureReported(id, configured: configured, now: now)
        case .probeResult(let id, let outcome): return probeResult(id, outcome, configured: configured, now: now)
        case .probeAborted(let id):
            health[id]?.isProbing = false
            return []
        case .probeDue(let id): return probeDue(id, configured: configured)
        }
    }

    private mutating func start(configured: (String) -> Bool) -> [Effect] {
        let first = candidates.first(where: configured) ?? preferred
        active = first
        guard first != preferred else {
            reason = nil
            return []
        }
        reason = .notConfigured
        return [.activate(first, .fallback)]
    }

    private mutating func userSelected(_ id: String) -> [Effect] {
        guard order.contains(id) else { return [] }
        var effects: [Effect] = []
        for source in order {
            if health[source]?.hasTimer == true { effects.append(.cancelSchedule(source)) }
            health[source] = SourceHealth()
        }
        preferred = id
        active = id
        reason = nil
        effects.append(.activate(id, .user))
        return effects
    }

    private mutating func probeDue(_ id: String, configured: (String) -> Bool) -> [Effect] {
        guard var h = health[id] else { return [] }
        let hadTimer = h.hasTimer
        h.hasTimer = false
        // A due timer on the active source is a deferred confirmation (`failureReported`), nothing else.
        let eligible = (isAhead(id) || (id == active && hadTimer)) && configured(id) && !h.isProbing
        if eligible { h.isProbing = true }
        health[id] = h
        return eligible ? [.probe(id)] : []
    }

    private mutating func failureReported(_ id: String, configured: (String) -> Bool, now: Duration) -> [Effect] {
        guard id == active, var h = health[id], configured(id), !h.isProbing, !h.hasTimer else { return [] }
        if let ended = h.lastProbeEnded, now - ended < schedule.minimumSpacing {
            h.hasTimer = true
            health[id] = h
            return [.schedule(id, after: schedule.minimumSpacing - (now - ended))]
        }
        h.isProbing = true
        health[id] = h
        return [.probe(id)]
    }

    private mutating func probeResult(
        _ id: String, _ outcome: SourceProbeOutcome, configured: (String) -> Bool, now: Duration
    ) -> [Effect] {
        // A result needs a probe in flight, except for the active source: the Library window's own connect.
        guard var h = health[id], h.isProbing || id == active else { return [] }
        h.isProbing = false
        h.lastProbeEnded = now
        h.outcome = outcome
        switch outcome {
        case .reachable:
            h.failures = 0
            health[id] = h
            return reachable(id, configured: configured)
        case .unreachable(let message):
            h.failures += 1
            health[id] = h
            if id == preferred { reason = .unreachable(message) }
        case .notConfigured:
            h.failures = 0
            health[id] = h
            if id == preferred { reason = .notConfigured }
        }
        if id == active || rank(id) > rank(active) { return advance(from: id, configured: configured, now: now) }
        // Ahead of the active source: look again later, unless it needs the user (not configured).
        guard case .unreachable = outcome, health[id]?.hasTimer == false else { return [] }
        health[id]?.hasTimer = true
        return [.schedule(id, after: schedule.delay(afterFailures: health[id]?.failures ?? 1))]
    }

    /// The first configured candidate after `id` that is not already being probed and was not probed within the
    /// minimum spacing. The spacing matters because `configuredChanged` re-advances on every defaults write while
    /// the active source is not set up; without it a source that answers quickly would be probed back to back.
    private mutating func advance(from id: String, configured: (String) -> Bool, now: Duration) -> [Effect] {
        let after = candidates.dropFirst(rank(id) + 1)
        let next = after.first { candidate in
            guard configured(candidate), let h = health[candidate], !h.isProbing else { return false }
            guard let ended = h.lastProbeEnded else { return true }
            return now - ended >= schedule.minimumSpacing
        }
        guard let next else { return [] }
        health[next]?.isProbing = true
        return [.probe(next)]
    }

    private mutating func reachable(_ id: String, configured: (String) -> Bool) -> [Effect] {
        guard id != active else {
            if id == preferred { reason = nil }
            return []
        }
        let kind: ActivationKind = id == preferred && isAhead(id) ? .restore : .fallback
        active = id
        if id == preferred { reason = nil }
        var effects: [Effect] = []
        // Timers only belong to sources ahead of the new active one.
        for source in candidates where health[source]?.hasTimer == true && !isAhead(source) {
            health[source]?.hasTimer = false
            effects.append(.cancelSchedule(source))
        }
        for source in candidates where isAhead(source) && configured(source) {
            guard let h = health[source], !h.hasTimer, !h.isProbing else { continue }
            health[source]?.hasTimer = true
            effects.append(.schedule(source, after: schedule.delay(afterFailures: max(1, h.failures))))
        }
        effects.append(.activate(id, kind))
        return effects
    }

    private mutating func configuredChanged(configured: (String) -> Bool, now: Duration) -> [Effect] {
        var effects: [Effect] = []
        for source in order where health[source]?.hasTimer == true && !configured(source) {
            health[source]?.hasTimer = false
            effects.append(.cancelSchedule(source))
        }
        if !configured(active) {
            // The active source was un-set-up: move on, exactly as if its connect had said so.
            effects += probeResult(
                active, .notConfigured("The music source isn't set up."), configured: configured, now: now)
        }
        effects += probeAhead(configured: configured, now: now)
        return effects
    }

    private mutating func retryRequested(configured: (String) -> Bool, now: Duration) -> [Effect] {
        var effects: [Effect] = []
        for source in order {
            health[source]?.failures = 0
            if health[source]?.hasTimer == true {
                health[source]?.hasTimer = false
                effects.append(.cancelSchedule(source))
            }
        }
        if !configured(active) {
            effects += probeResult(
                active, .notConfigured("The music source isn't set up."), configured: configured, now: now)
        }
        effects += probeAhead(configured: configured, now: now)
        return effects
    }

    /// A probe for every configured source ahead of the active one that has neither a probe nor a timer; a
    /// timer for the remaining spacing when one ended too recently.
    private mutating func probeAhead(configured: (String) -> Bool, now: Duration) -> [Effect] {
        var effects: [Effect] = []
        for source in candidates where isAhead(source) && configured(source) {
            guard var h = health[source], !h.isProbing, !h.hasTimer else { continue }
            if let ended = h.lastProbeEnded, now - ended < schedule.minimumSpacing {
                h.hasTimer = true
                effects.append(.schedule(source, after: schedule.minimumSpacing - (now - ended)))
            } else {
                h.isProbing = true
                effects.append(.probe(source))
            }
            health[source] = h
        }
        return effects
    }
}
