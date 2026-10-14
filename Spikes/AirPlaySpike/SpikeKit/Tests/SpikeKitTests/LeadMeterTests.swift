import Foundation
import Testing
@testable import SpikeKit

@Suite struct LeadMeterTests {
    @Test func classifiesSecondsAndMinutes() {
        let t0 = ContinuousClock.now
        var local = LeadMeter()
        local.record(lastEnqueued: 13, now: 10, at: t0)
        #expect(local.classification == .seconds)

        var air = LeadMeter()
        air.record(lastEnqueued: 105, now: 10, at: t0)
        #expect(air.classification == .minutes)
        #expect(air.current == 95)

        var mid = LeadMeter()
        mid.record(lastEnqueued: 30, now: 10, at: t0)
        #expect(mid.classification == .between)
    }

    @Test func tracksMaxAndDropsOldSamples() {
        let t0 = ContinuousClock.now
        var meter = LeadMeter()
        meter.record(lastEnqueued: 100, now: 0, at: t0)
        meter.record(lastEnqueued: 5, now: 0, at: t0.advanced(by: .seconds(90)))
        meter.record(lastEnqueued: 8, now: 0, at: t0.advanced(by: .seconds(100)))
        #expect(meter.max == 100)
        #expect(meter.maxInLast(seconds: 60) == 8)
        #expect(meter.maxInLast(seconds: 200) == 100)
        #expect(meter.classification == .seconds)
    }
}
