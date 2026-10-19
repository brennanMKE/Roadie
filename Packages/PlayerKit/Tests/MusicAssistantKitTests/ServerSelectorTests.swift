import Foundation
import Testing
@testable import MusicAssistantKit

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

struct ServerSelectorTests {
    typealias Ranking = MusicAssistantServerRanking

    private let a = makeServer("http://a.local:8095", id: "id-a", name: "A")
    private let b = makeServer("http://b.local:8095", id: "id-b", name: "B")

    private func candidates(_ servers: MusicAssistantServerConfiguration...) -> [Ranking.Candidate] {
        Ranking.candidates(servers, ssid: nil)
    }

    @Test func probesRunConcurrentlyWithoutHeaders() async throws {
        let fake = FakeInfo()
        fake.set("http://a.local:8095", .hang)
        fake.set("http://b.local:8095", .hang)
        let clock = ManualClock()
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: clock)
        let ranked = candidates(a, b)
        let task = Task { await selector.resolve(ranked) }
        // Both are in flight before any time passes. The fetcher takes a URL only: there is no header or token to pass.
        #expect(await waitFor { fake.calls.count == 2 && clock.sleeperCount == 2 })
        #expect(Set(fake.calls) == [a.address.baseURL, b.address.baseURL])
        clock.advance(by: .seconds(3))
        let result = await task.value
        #expect(result.decision == Ranking.Decision.none)
        #expect(result.outcomes == [a.id: .timedOut, b.id: .timedOut])
    }

    @Test func aLowerRankedSuccessWaitsForTheTimeoutOfAHigherOne() async throws {
        let fake = FakeInfo()
        fake.set("http://a.local:8095", .hang)
        fake.set("http://b.local:8095", .answer("id-b"))
        let clock = ManualClock()
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: clock)
        let ranked = candidates(a, b)
        let done = Box<MusicAssistantServerSelector.Result>()
        let task = Task {
            let result = await selector.resolve(ranked)
            done.set(result)
            return result
        }
        #expect(await waitFor { fake.calls.count == 2 && clock.sleeperCount == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(done.value == nil)
        clock.advance(by: .seconds(3))
        let result = await task.value
        #expect(result.decision == .chosen(ranked[1]))
        #expect(result.outcomes[a.id] == .timedOut)
        #expect(result.outcomes[b.id] == .reachable)
    }

    @Test func aDifferentServerAtTheAddressIsAMismatch() async {
        let fake = FakeInfo()
        fake.set("http://a.local:8095", .answer("someone-else"))
        fake.set("http://b.local:8095", .answer("id-b", schema: 20))
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: ManualClock())
        let result = await selector.resolve(candidates(a, b))
        #expect(result.decision == Ranking.Decision.none)
        #expect(result.outcomes == [a.id: .mismatch, b.id: .schemaUnsupported])
    }

    @Test func decidedEarlyCancelsTheRest() async {
        let fake = FakeInfo()
        fake.set("http://a.local:8095", .answer("id-a"))
        fake.set("http://b.local:8095", .hang)
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: ManualClock())
        let ranked = candidates(a, b)
        let result = await selector.resolve(ranked)
        #expect(result.decision == .chosen(ranked[0]))
        #expect(await waitFor { !fake.calls.contains(b.address.baseURL) || fake.cancelled.contains(b.address.baseURL) })
    }

    @Test func concurrentResolvesWithTheSameCandidatesShareOneRound() async {
        let fake = FakeInfo()
        fake.set("http://a.local:8095", .gated("id-a"))
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: ManualClock())
        let ranked = candidates(a)
        let first = Task { await selector.resolve(ranked) }
        #expect(await waitFor { fake.calls.count == 1 })
        let second = Task { await selector.resolve(ranked) }
        #expect(await waitFor { await selector.joined == 1 })
        fake.release()
        #expect(await first.value.decision == .chosen(ranked[0]))
        #expect(await second.value.decision == .chosen(ranked[0]))
        #expect(fake.calls.count == 1)
    }

    @Test func newerResolveCancelsAnOlderOne() async {
        let fake = FakeInfo()
        fake.set("http://a.local:8095", .hang)
        fake.set("http://b.local:8095", .answer("id-b"))
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: ManualClock())
        let older = Task { await selector.resolve(candidates(a)) }
        #expect(await waitFor { fake.calls.count == 1 })
        let newer = await selector.resolve(candidates(b))
        #expect(newer.decision == .chosen(candidates(b)[0]))
        #expect(await older.value.decision == .undecided)
        #expect(fake.cancelled.contains(a.address.baseURL))
    }

    @Test func sameURLForTwoServersFetchesOnceAndPicksTheMatchingID() async {
        let fake = FakeInfo()
        fake.set("http://homeassistant.local:8095", .answer("site-two"))
        let one = makeServer("http://homeassistant.local:8095", id: "site-one", name: "One")
        let two = makeServer("http://homeassistant.local:8095", id: "site-two", name: "Two")
        let selector = MusicAssistantServerSelector(fetch: fake.fetcher, clock: ManualClock())
        let ranked = candidates(one, two)
        let result = await selector.resolve(ranked)
        #expect(result.decision == .chosen(ranked[1]))
        #expect(result.outcomes == [one.id: .mismatch, two.id: .reachable])
        #expect(fake.calls.count == 1)
    }
}
