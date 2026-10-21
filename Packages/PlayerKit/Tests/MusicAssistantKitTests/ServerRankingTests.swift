import Foundation
import Testing
@testable import MusicAssistantKit

struct ServerRankingTests {
    typealias Ranking = MusicAssistantServerRanking

    @Test func serversOnTheCurrentNetworkComeFirstInListOrder() {
        let a = makeServer("http://a.local:8095", id: "a", name: "A", networks: ["X"])
        let b = makeServer("http://b.local:8095", id: "b", name: "B")
        let c = makeServer("http://c.local:8095", id: "c", name: "C", networks: ["X"])
        let ranked = Ranking.candidates([a, b, c], ssid: "X")
        #expect(ranked.map(\.server.name) == ["A", "C", "B"])
        #expect(ranked.map(\.basis) == [.network("X"), .network("X"), .listOrder])
    }

    @Test func noSSIDMeansListOrder() {
        let a = makeServer("http://a.local:8095", id: "a", name: "A")
        let b = makeServer("http://b.local:8095", id: "b", name: "B", networks: ["X"])
        let ranked = Ranking.candidates([a, b], ssid: nil)
        #expect(ranked.map(\.server.name) == ["A", "B"])
        #expect(ranked.allSatisfy { $0.basis == .listOrder })
        #expect(Ranking.candidates([a, b], ssid: "  ").map(\.server.name) == ["A", "B"])
    }

    @Test func ssidMatchIsExactAfterTrimming() {
        let home = makeServer("http://a.local:8095", id: "a", name: "A", networks: ["Home"])
        let other = makeServer("http://b.local:8095", id: "b", name: "B")
        #expect(Ranking.candidates([other, home], ssid: "Home ").first?.server.name == "A")
        #expect(Ranking.candidates([other, home], ssid: "home").first?.server.name == "B")
    }

    @Test func unverifiedServersAreNotCandidates() {
        let verified = makeServer("http://a.local:8095", id: "a", name: "A")
        let untested = makeServer(id: nil, name: "U")
        #expect(Ranking.candidates([untested, verified], ssid: nil).map(\.server.name) == ["A"])
    }

    @Test func decideWaitsForHigherRankedProbes() {
        let ranked = Ranking.candidates(
            [makeServer("http://a.local:8095", id: "a", name: "A"), makeServer("http://b.local:8095", id: "b", name: "B")],
            ssid: nil)
        let (a, b) = (ranked[0].server.id, ranked[1].server.id)
        #expect(Ranking.decide(ranked, outcomes: [b: .reachable]) == .undecided)
        #expect(Ranking.decide(ranked, outcomes: [a: .unreachable, b: .reachable]) == .chosen(ranked[1]))
    }

    @Test func decidePrefersHigherRank() {
        let ranked = Ranking.candidates(
            [makeServer("http://a.local:8095", id: "a", name: "A"), makeServer("http://b.local:8095", id: "b", name: "B")],
            ssid: nil)
        let outcomes = [ranked[0].server.id: Ranking.Outcome.reachable, ranked[1].server.id: .reachable]
        #expect(Ranking.decide(ranked, outcomes: outcomes) == .chosen(ranked[0]))
        // Decided as soon as the top one answers, whatever the rest are doing.
        #expect(Ranking.decide(ranked, outcomes: [ranked[0].server.id: .reachable]) == .chosen(ranked[0]))
    }

    @Test func mismatchAndTimeoutAreNotReachable() {
        let ranked = Ranking.candidates(
            [
                makeServer("http://a.local:8095", id: "a", name: "A"), makeServer("http://b.local:8095", id: "b", name: "B"),
                makeServer("http://c.local:8095", id: "c", name: "C"),
            ], ssid: nil)
        let outcomes: [UUID: Ranking.Outcome] = [
            ranked[0].server.id: .mismatch, ranked[1].server.id: .timedOut, ranked[2].server.id: .schemaUnsupported,
        ]
        #expect(Ranking.decide(ranked, outcomes: outcomes) == Ranking.Decision.none)
    }

    @Test func allFailedIsNone() {
        let ranked = Ranking.candidates([makeServer("http://a.local:8095", id: "a", name: "A")], ssid: nil)
        #expect(Ranking.decide(ranked, outcomes: [ranked[0].server.id: .unreachable]) == Ranking.Decision.none)
        #expect(Ranking.decide([], outcomes: [:]) == Ranking.Decision.none)
    }

    @Test func reasonTexts() {
        let home = makeServer("http://a.local:8095", id: "a", name: "Home", networks: ["Attic"])
        #expect(Ranking.reason(for: Ranking.Candidate(server: home, basis: .network("Attic"))) == "Home \u{2014} on network Attic")
        #expect(Ranking.reason(for: Ranking.Candidate(server: home, basis: .listOrder)) == "Home \u{2014} first reachable")
        let ip = makeServer("http://100.100.1.1:8095", id: "b", name: "Studio")
        #expect(Ranking.reason(for: Ranking.Candidate(server: ip, basis: .listOrder)) == "Studio \u{2014} via Tailscale")
        let magic = makeServer("https://box.tail.ts.net", id: "c", name: "Box")
        #expect(Ranking.reason(for: Ranking.Candidate(server: magic, basis: .listOrder)) == "Box \u{2014} via Tailscale")
        #expect(Ranking.reason(for: Ranking.Decision.none, hasCandidates: true) == "No Music Assistant server reachable")
        #expect(Ranking.reason(for: Ranking.Decision.none, hasCandidates: false) == "No Music Assistant server tested yet")
        #expect(Ranking.reason(for: .undecided, hasCandidates: true) == nil)
        // Outside 100.64.0.0/10 is not Tailscale.
        #expect(!Ranking.isTailscale(URL(string: "http://100.128.0.1:8095")!))
        #expect(!Ranking.isTailscale(URL(string: "http://192.168.1.2:8095")!))
    }

    @Test func reasonTextNamesTheHostWhenTheNameIsGeneric() {
        let server = makeServer("http://a.local:8095", id: "a", name: "Music Assistant (abc123)")
        let text = Ranking.reason(for: Ranking.Candidate(server: server, basis: .listOrder))
        #expect(text == "a.local \u{2014} first reachable")
        #expect(!text.contains("("))
        #expect(!text.contains("Music Assistant"))
    }
}
