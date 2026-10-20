import Testing
@testable import LibraryBrowser

private typealias Policy = LibraryFallbackPolicy

/// A policy plus the configured flags and a clock the test sets, so each step reads as one line.
private struct Run {
    var policy: Policy
    var configured: [String: Bool]
    var now: Duration = .zero

    init(order: [String] = ["server", "folder"], preferred: String = "server", configured: [String: Bool]? = nil) {
        policy = Policy(order: order, preferred: preferred)
        self.configured = configured ?? Dictionary(uniqueKeysWithValues: order.map { ($0, true) })
    }

    @discardableResult
    mutating func send(_ event: Policy.Event, at seconds: Int? = nil) -> [Policy.Effect] {
        if let seconds { now = .seconds(seconds) }
        let flags = configured
        return policy.handle(event, configured: { flags[$0] ?? false }, now: now)
    }

    /// Server failed its connect and the folder answered: the folder is active and Server has a 5 s timer.
    mutating func enterFallback() {
        send(.start)
        send(.probeResult("server", .unreachable("down")), at: 1)
        send(.probeResult("folder", .reachable), at: 2)
    }

    var timers: [String] { policy.health.filter { $0.value.hasTimer }.keys.sorted() }

    /// The rules from the plan, as one place to check them.
    func checkInvariants() {
        #expect(policy.order.contains(policy.active))
        if policy.active != policy.preferred { #expect(policy.reason != nil) }
        let candidates = policy.candidates
        for (id, health) in policy.health {
            #expect(!(health.isProbing && health.hasTimer))
            if health.hasTimer {
                let ahead = candidates.firstIndex(of: id)! < candidates.firstIndex(of: policy.active)!
                #expect(configured[id] == true)
                #expect(ahead || id == policy.active)
            }
        }
    }
}

struct LibraryFallbackPolicyTests {
    @Test func startUsesThePreferredSourceWhenItIsConfigured() {
        var run = Run()
        #expect(run.send(.start) == [])
        #expect(run.policy.active == "server")
        #expect(run.policy.reason == nil)
    }

    @Test func startFallsBackWithoutProbingWhenThePreferredIsNotSetUp() {
        var run = Run(configured: ["server": false, "folder": true])
        let effects = run.send(.start)
        #expect(effects == [.activate("folder", .fallback)])
        #expect(run.policy.reason == .notConfigured)
        #expect(!effects.contains { if case .probe = $0 { true } else { false } })
        #expect(!effects.contains { if case .schedule = $0 { true } else { false } })
        #expect(run.timers.isEmpty)
    }

    @Test func startStaysOnThePreferredWhenNothingIsConfigured() {
        var run = Run(configured: ["server": false, "folder": false])
        #expect(run.send(.start) == [])
        #expect(run.policy.active == "server")
        #expect(run.policy.reason == nil)
    }

    @Test func aFailedConnectOnThePreferredProbesTheNextCandidate() {
        var run = Run()
        run.send(.start)
        #expect(run.send(.probeResult("server", .unreachable("down"))) == [.probe("folder")])
        #expect(run.policy.active == "server")
        #expect(run.policy.reason == .unreachable("down"))
    }

    @Test func aReachableCandidateIsActivatedAndThePreferredIsRetried() {
        var run = Run()
        run.send(.start)
        run.send(.probeResult("server", .unreachable("down")))
        let effects = run.send(.probeResult("folder", .reachable))
        #expect(effects == [.schedule("server", after: .seconds(5)), .activate("folder", .fallback)])
        #expect(run.policy.health["server"]?.hasTimer == true)
        #expect(run.policy.active == "folder")
        run.checkInvariants()
    }

    @Test func anUnreachableCandidateLeavesTheActiveAloneWithNoTimer() {
        var run = Run()
        run.send(.start)
        run.send(.probeResult("server", .unreachable("down")))
        #expect(run.send(.probeResult("folder", .unreachable("x"))) == [])
        #expect(run.policy.active == "server")
        #expect(run.timers.isEmpty)
    }

    @Test func retriesBackOffAndCapAtFiveMinutes() {
        var run = Run()
        run.enterFallback()
        var delays: [Duration] = [.seconds(5)]  // scheduled on entering the fallback
        for step in 0..<7 {
            #expect(run.send(.probeDue("server"), at: 10 + step * 400) == [.probe("server")])
            let effects = run.send(.probeResult("server", .unreachable("down")), at: 10 + step * 400)
            guard case .schedule("server", let after)? = effects.first else {
                Issue.record("expected a schedule, got \(effects)")
                return
            }
            delays.append(after)
        }
        #expect(delays == [5, 10, 20, 40, 80, 160, 300, 300].map { Duration.seconds($0) })
        #expect(RetrySchedule.default.delay(afterFailures: 9) == .seconds(300))
        #expect(RetrySchedule.default.delay(afterFailures: 1) == .seconds(5))
    }

    @Test func probeDueProbesOnlyAConfiguredSourceAhead() {
        var run = Run()
        run.enterFallback()
        #expect(run.send(.probeDue("folder")) == [])  // the active source is never polled
        run.configured["server"] = false
        #expect(run.send(.probeDue("server")) == [])
        run.configured["server"] = true
        #expect(run.send(.probeDue("server")) == [.probe("server")])
        #expect(run.send(.probeDue("server")) == [])  // already probing
    }

    @Test func thePreferredComingBackIsRestoredAndClearsTheReason() {
        var run = Run()
        run.enterFallback()
        run.send(.probeDue("server"), at: 10)
        #expect(run.send(.probeResult("server", .reachable), at: 11) == [.activate("server", .restore)])
        #expect(run.policy.reason == nil)
        #expect(run.policy.active == "server")
        #expect(run.timers.isEmpty)
    }

    @Test func aReportedFailureOnTheActiveSourceIsConfirmedOnce() {
        var run = Run()
        run.send(.start)
        #expect(run.send(.failureReported("server")) == [.probe("server")])
        #expect(run.send(.failureReported("server")) == [])
        #expect(run.send(.failureReported("folder")) == [])
        #expect(run.send(.probeResult("server", .unreachable("x"))) == [.probe("folder")])
    }

    @Test func aReportWithinTheMinimumSpacingIsDeferred() {
        var run = Run()
        run.send(.start)
        run.send(.probeResult("server", .unreachable("x")), at: 10)
        #expect(run.send(.failureReported("server"), at: 12) == [.schedule("server", after: .seconds(3))])
        #expect(run.send(.probeDue("server"), at: 15) == [.probe("server")])
    }

    @Test func userSelectionMakesTheChoicePreferredAndActiveAndCancelsRetries() {
        var run = Run()
        run.enterFallback()
        #expect(run.send(.userSelected("folder")) == [.cancelSchedule("server"), .activate("folder", .user)])
        #expect(run.policy.preferred == "folder")
        #expect(run.policy.active == "folder")
        #expect(run.policy.reason == nil)
        #expect(run.policy.candidates == ["folder", "server"])
        #expect(run.send(.userSelected("server")) == [.activate("server", .user)])
        #expect(run.send(.userSelected("musicAssistant")) == [])
    }

    @Test func aProbeThatEndsAfterAUserSelectionIsIgnored() {
        var run = Run()
        run.enterFallback()
        run.send(.probeDue("server"), at: 10)
        run.send(.userSelected("folder"), at: 11)
        #expect(run.send(.probeResult("server", .reachable), at: 12) == [])
        #expect(run.policy.active == "folder")
    }

    @Test func configuredChangedProbesANewlyConfiguredPreferredAtOnce() {
        var run = Run(configured: ["server": false, "folder": true])
        run.send(.start)
        run.configured["server"] = true
        #expect(run.send(.configuredChanged) == [.probe("server")])
        #expect(run.send(.configuredChanged) == [])
    }

    @Test func configuredChangedCancelsTimersOfSourcesNoLongerConfigured() {
        var run = Run()
        run.enterFallback()
        run.configured["server"] = false
        #expect(run.send(.configuredChanged) == [.cancelSchedule("server")])
        #expect(run.timers.isEmpty)
    }

    @Test func theActiveSourceBecomingUnconfiguredAdvances() {
        var run = Run()
        run.send(.start)
        run.send(.userSelected("folder"))
        run.configured["folder"] = false
        #expect(run.send(.configuredChanged) == [.probe("server")])
        #expect(run.send(.probeResult("server", .reachable)) == [.activate("server", .fallback)])
        #expect(run.policy.reason == .notConfigured)
        #expect(run.policy.active == "server")
    }

    @Test func anUnconfiguredActiveSourceDoesNotReprobeTheNextOneOnEverySettingsChange() {
        var run = Run()
        run.send(.start)
        run.send(.userSelected("folder"))
        run.configured["folder"] = false
        #expect(run.send(.configuredChanged, at: 10) == [.probe("server")])
        #expect(run.send(.probeResult("server", .unreachable("down")), at: 11) == [])
        // Any later defaults write (a window frame, the time mode) within the spacing probes nothing.
        #expect(run.send(.configuredChanged, at: 12) == [])
        #expect(run.send(.configuredChanged, at: 15) == [])
        #expect(run.send(.configuredChanged, at: 16) == [.probe("server")])
        #expect(run.policy.active == "folder")
    }

    @Test func retryRequestedResetsTheBackoffAndProbesNow() {
        var run = Run()
        run.enterFallback()
        for step in 0..<2 {
            run.send(.probeDue("server"), at: 10 + step * 30)
            run.send(.probeResult("server", .unreachable("down")), at: 10 + step * 30)
        }
        #expect(run.policy.health["server"]?.failures == 3)
        #expect(run.send(.retryRequested, at: 1000) == [.cancelSchedule("server"), .probe("server")])
        #expect(run.send(.probeResult("server", .unreachable("down")), at: 1001) == [.schedule("server", after: .seconds(5))])
    }

    @Test func probeAbortedOnlyClearsTheInFlightFlag() {
        var run = Run()
        run.enterFallback()
        #expect(run.send(.probeDue("server"), at: 10) == [.probe("server")])
        #expect(run.send(.probeAborted("server")) == [])
        #expect(run.policy.health["server"]?.isProbing == false)
        #expect(run.policy.health["server"]?.failures == 1)
        #expect(run.send(.probeDue("server"), at: 11) == [.probe("server")])
    }

    @Test func candidatesFollowTheListOrderAfterThePreferred() {
        var run = Run(order: ["musicAssistant", "server", "folder"], preferred: "folder")
        #expect(run.send(.start) == [])
        #expect(run.send(.probeResult("folder", .unreachable("x"))) == [.probe("musicAssistant")])
        #expect(run.send(.probeResult("musicAssistant", .unreachable("y"))) == [.probe("server")])
        let effects = run.send(.probeResult("server", .reachable))
        #expect(effects == [
            .schedule("folder", after: .seconds(5)), .schedule("musicAssistant", after: .seconds(5)),
            .activate("server", .fallback),
        ])
        #expect(run.policy.reason == .unreachable("x"))
    }

    @Test func anIntermediateSourceComingBackIsAFallbackNotARestore() {
        var run = Run(order: ["musicAssistant", "server", "folder"], preferred: "folder")
        run.send(.start)
        run.send(.probeResult("folder", .unreachable("x")))
        run.send(.probeResult("musicAssistant", .unreachable("y")))
        run.send(.probeResult("server", .reachable))
        #expect(run.send(.probeDue("musicAssistant"), at: 10) == [.probe("musicAssistant")])
        #expect(run.send(.probeResult("musicAssistant", .reachable), at: 11) == [.activate("musicAssistant", .fallback)])
        #expect(run.policy.reason == .unreachable("x"))
        #expect(run.policy.health["folder"]?.hasTimer == true)
    }

    @Test func invariantsHoldAcrossAScriptedSequence() {
        var run = Run(order: ["musicAssistant", "server", "folder"], preferred: "server")
        func step(_ event: Policy.Event, at seconds: Int) {
            run.send(event, at: seconds)
            run.checkInvariants()
        }
        step(.start, at: 0)
        step(.probeResult("server", .unreachable("a")), at: 1)  // probes musicAssistant
        step(.probeResult("musicAssistant", .unreachable("b")), at: 2)  // probes folder
        step(.probeResult("folder", .reachable), at: 3)
        step(.failureReported("folder"), at: 4)
        step(.probeDue("server"), at: 10)
        step(.probeResult("server", .unreachable("c")), at: 11)
        step(.probeDue("musicAssistant"), at: 20)
        step(.probeAborted("musicAssistant"), at: 21)
        run.configured["musicAssistant"] = false
        step(.configuredChanged, at: 22)
        step(.retryRequested, at: 100)
        step(.probeResult("server", .reachable), at: 101)
        step(.userSelected("folder"), at: 102)
        step(.configuredChanged, at: 103)
        #expect(run.policy.active == "folder")
    }
}
