import Foundation
import Testing
@testable import SendspinKit

/// Deterministic noise.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct SendspinTimeFilterTests {
    @Test func firstSampleSetsOffsetWithoutDrift() {
        var filter = SendspinTimeFilter()
        filter.update(measurement: 5_000, maxError: 100, timeAdded: 1_000)
        #expect(filter.sampleCount == 1)
        #expect(filter.computeServerTime(2_000) == 7_000)
        #expect(filter.computeServerTime(10_000_000) == 10_005_000)
        #expect(filter.computeClientTime(7_000) == 2_000)
        #expect(filter.error == 50)
    }

    @Test func secondSampleEstimatesDrift() {
        var filter = SendspinTimeFilter()
        filter.update(measurement: 5_000, maxError: 10, timeAdded: 1_000_000)
        filter.update(measurement: 5_100, maxError: 10, timeAdded: 2_000_000)
        #expect(filter.sampleCount == 2)
        #expect(filter.computeServerTime(2_000_000) == 2_005_100)
        // A third consistent sample runs the Kalman step; the drift from the second sample is significant and used.
        filter.update(measurement: 5_200, maxError: 10, timeAdded: 3_000_000)
        #expect(abs(filter.computeServerTime(4_000_000) - 4_005_300) <= 5)
    }

    @Test func convergesOnConstantOffset() {
        var filter = SendspinTimeFilter()
        var rng = SplitMix64(state: 42)
        for index in 1...20 {
            let noise = Int64.random(in: -200...200, using: &rng)
            filter.update(measurement: 5_000 + noise, maxError: 500, timeAdded: Int64(index) * 1_000_000)
        }
        let x: Int64 = 21_000_000
        #expect(abs(filter.computeClientTime(filter.computeServerTime(x)) - x) <= 1)
        #expect(abs(filter.computeServerTime(x) - x - 5_000) < 100)
    }

    @Test func tracksDriftOf100ppm() {
        var filter = SendspinTimeFilter()
        var rng = SplitMix64(state: 7)
        let offset: Double = 3_000
        func serverOffset(at client: Int64) -> Double { offset + Double(client) * 1e-4 }
        for second in 1...120 {
            let client = Int64(second) * 1_000_000
            let noise = Double(Int64.random(in: -50...50, using: &rng))
            filter.update(measurement: Int64((serverOffset(at: client) + noise).rounded()), maxError: 100, timeAdded: client)
        }
        let probe: Int64 = 121_000_000
        let truth = Double(probe) + serverOffset(at: probe)
        #expect(abs(Double(filter.computeServerTime(probe)) - truth) < 200)
        #expect(abs(Double(filter.computeClientTime(Int64(truth))) - Double(probe)) < 200)
    }

    @Test func ignoresNonIncreasingTimeAndNonPositiveError() {
        var filter = SendspinTimeFilter()
        filter.update(measurement: 5_000, maxError: 100, timeAdded: 1_000)
        filter.update(measurement: 9_000, maxError: 100, timeAdded: 1_000)
        filter.update(measurement: 9_000, maxError: 100, timeAdded: 500)
        filter.update(measurement: 9_000, maxError: 0, timeAdded: 2_000)
        filter.update(measurement: 9_000, maxError: -5, timeAdded: 3_000)
        #expect(filter.sampleCount == 1)
        #expect(filter.computeServerTime(1_000) == 6_000)
        filter.reset()
        #expect(filter.sampleCount == 0)
    }

    @Test func burstKeepsTheLowestMaxErrorSample() {
        var burst = SendspinClockBurst()
        let wide = SendspinClockSample(t1: 0, t2: 5_500, t3: 5_550, t4: 1_050)
        let tight = SendspinClockSample(t1: 2_000, t2: 7_100, t3: 7_150, t4: 2_250)
        let negative = SendspinClockSample(t1: 3_000, t2: 9_000, t3: 9_500, t4: 3_100)
        burst.add(wide)
        burst.add(tight)
        burst.add(negative)
        #expect(wide.maxError == 500)
        #expect(tight.maxError == 100)
        #expect(negative.maxError < 0)
        #expect(burst.best == tight)
        #expect(tight.measurement == ((7_100 - 2_000) + (7_150 - 2_250)) / 2)
        for _ in 0..<10 { burst.add(wide) }
        #expect(burst.samples.count == 8)
        #expect(burst.isComplete)
    }
}
