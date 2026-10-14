import Foundation
import Testing
@testable import AudioCore

@Suite struct ProgressiveReadPolicyTests {
    var policy: ProgressiveReadPolicy {
        var policy = ProgressiveReadPolicy()
        policy.waitWindowBytes = 4096
        policy.maxSideFetchBytes = 8192
        return policy
    }

    @Test func servesWhatIsAvailable() {
        #expect(policy.decide(offset: 0, count: 512, available: 1000, finalSize: 100_000, sideFetched: 0) == .serve)
        #expect(policy.decide(offset: 488, count: 512, available: 1000, finalSize: 100_000, sideFetched: 0) == .serve)
    }

    @Test func waitsForBytesJustAheadOfTheFrontier() {
        #expect(policy.decide(offset: 900, count: 500, available: 1000, finalSize: 100_000, sideFetched: 0) == .wait(through: 1400))
    }

    @Test func clampsTheWaitToTheFinalSize() {
        #expect(policy.decide(offset: 1900, count: 500, available: 1000, finalSize: 2000, sideFetched: 0) == .wait(through: 2000))
    }

    @Test func sideFetchesAFarJump() {
        #expect(
            policy.decide(offset: 1_000_000, count: 512, available: 1000, finalSize: 2_000_000, sideFetched: 0)
                == .sideFetch(1_000_000..<1_000_512))
    }

    @Test func givesUpPastTheSideFetchBudget() {
        #expect(policy.decide(offset: 1_000_000, count: 512, available: 1000, finalSize: 2_000_000, sideFetched: 8000) == .giveUp)
        #expect(policy.decide(offset: 1_000_000, count: 192, available: 1000, finalSize: 2_000_000, sideFetched: 8000) != .giveUp)
    }

    @Test func readsAtOrPastTheEndAreEndOfFile() {
        #expect(policy.decide(offset: 2000, count: 512, available: 2000, finalSize: 2000, sideFetched: 0) == .endOfFile)
        #expect(policy.decide(offset: 2500, count: 512, available: 2000, finalSize: 2000, sideFetched: 0) == .endOfFile)
    }

    @Test func aCompleteFileAlwaysServes() {
        #expect(policy.decide(offset: 1_999_000, count: 4096, available: 2_000_000, finalSize: 2_000_000, sideFetched: 0) == .serve)
    }

    @Test func prerollBytesFollowTheBitrateWithAFloorAndACap() {
        let policy = ProgressiveReadPolicy()
        #expect(policy.prerollBytes(bitrateKbps: 128, finalSize: 10_000_000) == 262_144)   // 32,000 < the floor
        #expect(policy.prerollBytes(bitrateKbps: nil, finalSize: 10_000_000) == 262_144)   // 192 kbps -> 48,000
        #expect(policy.prerollBytes(bitrateKbps: 1411, finalSize: 10_000_000) == 352_750)  // 1411 * 125 * 2
        #expect(policy.prerollBytes(bitrateKbps: 128, finalSize: 100_000) == 100_000)
    }
}
