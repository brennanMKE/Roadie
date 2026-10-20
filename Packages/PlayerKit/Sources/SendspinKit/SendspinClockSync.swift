import Foundation

/// The client's clock in microseconds.
public protocol SendspinClock: Sendable {
    func nowMicros() -> Int64
}

/// `CLOCK_UPTIME_RAW` in µs: the same base as `mach_absolute_time`, so as `AVAudioTime` host time (#0106).
public struct SystemSendspinClock: SendspinClock {
    public init() {}
    public func nowMicros() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000) }
}

/// One NTP-style exchange: t1 sent (client), t2 server received, t3 server sent, t4 received (client).
public struct SendspinClockSample: Sendable, Equatable {
    public var t1: Int64
    public var t2: Int64
    public var t3: Int64
    public var t4: Int64

    public init(t1: Int64, t2: Int64, t3: Int64, t4: Int64) {
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
    }

    public var measurement: Int64 { ((t2 - t1) + (t3 - t4)) / 2 }
    public var maxError: Int64 { ((t4 - t1) - (t3 - t2)) / 2 }
}

/// Up to `size` sequential exchanges; only the lowest positive `maxError` sample feeds the filter.
public struct SendspinClockBurst: Sendable {
    public static let defaultSize = 8
    public let size: Int
    public private(set) var samples: [SendspinClockSample] = []

    public init(size: Int = SendspinClockBurst.defaultSize) { self.size = size }

    public var isComplete: Bool { samples.count >= size }

    public mutating func add(_ sample: SendspinClockSample) {
        if !isComplete { samples.append(sample) }
    }

    public var best: SendspinClockSample? {
        samples.filter { $0.maxError > 0 }.min { $0.maxError < $1.maxError }
    }
}

/// The filter plus convergence bookkeeping.
public struct SendspinClockState: Sendable {
    public private(set) var filter = SendspinTimeFilter()
    public private(set) var acceptedSamples = 0
    public private(set) var finishedBursts = 0

    public init() {}

    /// At least two samples accepted and one burst finished.
    public var isConverged: Bool { acceptedSamples >= 2 && finishedBursts >= 1 }

    public mutating func finish(_ burst: SendspinClockBurst) {
        if let best = burst.best {
            let before = filter.lastUpdateMicros
            filter.update(measurement: best.measurement, maxError: best.maxError, timeAdded: best.t4)
            if filter.lastUpdateMicros != before { acceptedSamples += 1 }
        }
        finishedBursts += 1
    }

    public mutating func reset() {
        filter.reset()
        acceptedSamples = 0
        finishedBursts = 0
    }
}
