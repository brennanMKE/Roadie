import Foundation

/// When an automatic preset change is due (design §2.4). Times are passed in by the caller; no clocks here.
public struct AutoAdvanceClock: Sendable {
    public struct Policy: Equatable, Sendable {
        public var isEnabled: Bool
        public var interval: TimeInterval
        public var varies: Bool
        public static let maxExtra: TimeInterval = 10

        public init(isEnabled: Bool, interval: TimeInterval, varies: Bool) {
            self.isEnabled = isEnabled
            self.interval = interval
            self.varies = varies
        }
    }

    /// Setting it re-plans from the last restart.
    public var policy: Policy {
        didSet { if let lastRestart { plan(from: lastRestart) } }
    }
    public private(set) var deadline: TimeInterval?
    public private(set) var isSuspended: Bool = false

    private var random: SplitMix64
    private var lastRestart: TimeInterval?
    private var suspendedAt: TimeInterval?
    /// Time spent suspended since the last restart, so a re-plan keeps it.
    private var suspendedTotal: TimeInterval = 0

    public init(policy: Policy, seed: UInt64) {
        self.policy = policy
        self.random = SplitMix64(seed: seed)
    }

    /// deadline = now + interval (+ uniform 0…maxExtra if varies); nil if disabled.
    public mutating func restart(at now: TimeInterval) {
        lastRestart = now
        suspendedTotal = 0
        if isSuspended { suspendedAt = now }
        plan(from: now)
    }

    public mutating func suspend(at now: TimeInterval) {
        guard !isSuspended else { return }
        isSuspended = true
        suspendedAt = now
    }

    /// deadline += suspended duration.
    public mutating func resume(at now: TimeInterval) {
        guard isSuspended else { return }
        isSuspended = false
        let paused = max(0, now - (suspendedAt ?? now))
        suspendedAt = nil
        suspendedTotal += paused
        if let deadline { self.deadline = deadline + paused }
    }

    /// True once when `now` reaches the deadline while not suspended; clears the deadline.
    public mutating func isDue(at now: TimeInterval) -> Bool {
        guard !isSuspended, let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }

    private mutating func plan(from start: TimeInterval) {
        guard policy.isEnabled else { deadline = nil; return }
        var extra: TimeInterval = 0
        if policy.varies { extra = Double.random(in: 0...Policy.maxExtra, using: &random) }
        deadline = start + policy.interval + extra + suspendedTotal
    }
}
