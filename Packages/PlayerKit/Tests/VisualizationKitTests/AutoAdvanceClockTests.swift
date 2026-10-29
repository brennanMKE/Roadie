import Foundation
import Testing
@testable import VisualizationKit

struct AutoAdvanceClockTests {
    private func fixed(_ interval: TimeInterval = 16) -> AutoAdvanceClock {
        AutoAdvanceClock(policy: .init(isEnabled: true, interval: interval, varies: false), seed: 1)
    }

    @Test func fixedIntervalIsDueAtTheDeadline() {
        var clock = fixed()
        clock.restart(at: 0)
        #expect(clock.deadline == 16)
        let early = clock.isDue(at: 15.99)
        #expect(!early)
        let onTime = clock.isDue(at: 16.0)
        #expect(onTime)
        let again = clock.isDue(at: 17)
        #expect(!again)
        #expect(clock.deadline == nil)
    }

    @Test func varyingAddsUpToTenSeconds() throws {
        var clock = AutoAdvanceClock(policy: .init(isEnabled: true, interval: 16, varies: true), seed: 3)
        var deadlines: [TimeInterval] = []
        for _ in 0..<200 {
            clock.restart(at: 0)
            deadlines.append(try #require(clock.deadline))
        }
        #expect(deadlines.allSatisfy { $0 >= 16 && $0 <= 26 })
        #expect(Set(deadlines).count > 1)
    }

    @Test func restartAfterAManualChangePushesTheDeadline() {
        var clock = fixed()
        clock.restart(at: 0)
        clock.restart(at: 10)
        #expect(clock.deadline == 26)
        let old = clock.isDue(at: 16)
        #expect(!old)
        let new = clock.isDue(at: 26)
        #expect(new)
    }

    @Test func suspendedTimeDoesNotCount() {
        var clock = fixed()
        clock.restart(at: 0)
        clock.suspend(at: 10)
        #expect(clock.isSuspended)
        let whileSuspended = clock.isDue(at: 30)
        #expect(!whileSuspended)
        clock.resume(at: 40)
        #expect(clock.deadline == 46)
        let before = clock.isDue(at: 45.9)
        #expect(!before)
        let due = clock.isDue(at: 46)
        #expect(due)
    }

    @Test func disabledIsNeverDue() {
        var clock = AutoAdvanceClock(policy: .init(isEnabled: false, interval: 16, varies: false), seed: 1)
        clock.restart(at: 0)
        #expect(clock.deadline == nil)
        let due = clock.isDue(at: 10_000)
        #expect(!due)
    }

    @Test func changingThePolicyReplansFromTheLastRestart() {
        var clock = fixed()
        clock.restart(at: 5)
        clock.policy.interval = 30
        #expect(clock.deadline == 35)
        clock.policy.isEnabled = false
        #expect(clock.deadline == nil)
        clock.policy.isEnabled = true
        #expect(clock.deadline == 35)
    }
}
