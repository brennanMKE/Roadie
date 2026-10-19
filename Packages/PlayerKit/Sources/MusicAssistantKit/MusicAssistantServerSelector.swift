import Foundation
import os

/// Runs the `/info` probes for automatic server choice (#0075). Every candidate is probed at once, unauthenticated
/// (the fetcher takes a URL only: no header, no token), and the decision follows rank order through
/// `MusicAssistantServerRanking.decide`. Logs carry counts only.
public actor MusicAssistantServerSelector {
    /// `GET /info` on a base URL. No headers, no token.
    public typealias InfoFetcher = @Sendable (URL) async throws -> MAServerInfo

    public struct Result: Hashable, Sendable {
        public var decision: MusicAssistantServerRanking.Decision
        public var outcomes: [UUID: MusicAssistantServerRanking.Outcome]

        public init(decision: MusicAssistantServerRanking.Decision, outcomes: [UUID: MusicAssistantServerRanking.Outcome]) {
            self.decision = decision
            self.outcomes = outcomes
        }
    }

    private enum Probe: Sendable {
        case info(MAServerInfo)
        case failed
        case timedOut
        case cancelled
    }

    private let fetch: InfoFetcher
    private let sleep: @Sendable (Duration) async throws -> Void
    private let probeTimeout: Duration
    private var running: (id: UUID, candidates: [MusicAssistantServerRanking.Candidate], task: Task<Result, Never>)?
    private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "MusicAssistantSelection")
    /// Calls that shared a running round, for tests.
    private(set) var joined = 0

    public init(fetch: @escaping InfoFetcher, clock: any Clock<Duration> = ContinuousClock(), probeTimeout: Duration = .seconds(3)) {
        self.fetch = fetch
        self.sleep = { try await clock.sleep(for: $0) }
        self.probeTimeout = probeTimeout
    }

    /// The production fetcher: `/info` through URLSession with a 3 s timeout.
    public static let urlSessionFetcher: InfoFetcher = {
        try await MusicAssistantClient.serverInfo(at: $0, http: URLSessionHTTPTransport(), timeout: .seconds(3))
    }

    /// Probes every candidate concurrently and returns as soon as the decision is no longer `.undecided` (cancelling
    /// the rest) or every probe is done. A call made while one with the same candidates runs shares it; a call with
    /// other candidates cancels the running one, whose caller then gets `.undecided`.
    public func resolve(_ candidates: [MusicAssistantServerRanking.Candidate]) async -> Result {
        if let running, running.candidates == candidates {
            joined += 1
            return await running.task.value
        }
        running?.task.cancel()
        let id = UUID()
        let fetch = fetch
        let sleep = sleep
        let timeout = probeTimeout
        let task = Task { await Self.run(candidates, fetch: fetch, sleep: sleep, timeout: timeout) }
        running = (id, candidates, task)
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if running?.id == id { running = nil }
        let counts = Dictionary(grouping: result.outcomes.values, by: { $0 }).mapValues(\.count)
        log.info(
            "resolved \(Self.kind(result.decision), privacy: .public): \(candidates.count) candidates, \(counts.count) outcome kinds, reachable \(counts[.reachable] ?? 0), mismatch \(counts[.mismatch] ?? 0)"
        )
        return result
    }

    private static func kind(_ decision: MusicAssistantServerRanking.Decision) -> String {
        switch decision {
        case .undecided: "undecided"
        case .chosen: "chosen"
        case .none: "none"
        }
    }

    private static func run(
        _ candidates: [MusicAssistantServerRanking.Candidate], fetch: @escaping InfoFetcher,
        sleep: @escaping @Sendable (Duration) async throws -> Void, timeout: Duration
    ) async -> Result {
        guard !candidates.isEmpty else { return Result(decision: .none, outcomes: [:]) }
        // Two servers at the same URL (the same `.local` name at two sites) share one fetch.
        var urls: [URL] = []
        for candidate in candidates where !urls.contains(candidate.server.address.baseURL) {
            urls.append(candidate.server.address.baseURL)
        }
        return await withTaskGroup(of: (URL, Probe).self) { group in
            for url in urls {
                group.addTask { (url, await probe(url, fetch: fetch, sleep: sleep, timeout: timeout)) }
            }
            var outcomes: [UUID: MusicAssistantServerRanking.Outcome] = [:]
            for await (url, probe) in group {
                for candidate in candidates where candidate.server.address.baseURL == url {
                    if let outcome = outcome(of: probe, for: candidate.server) { outcomes[candidate.server.id] = outcome }
                }
                let decision = MusicAssistantServerRanking.decide(candidates, outcomes: outcomes)
                if decision != .undecided {
                    group.cancelAll()
                    return Result(decision: decision, outcomes: outcomes)
                }
            }
            return Result(decision: MusicAssistantServerRanking.decide(candidates, outcomes: outcomes), outcomes: outcomes)
        }
    }

    private static func outcome(of probe: Probe, for server: MusicAssistantServerConfiguration) -> MusicAssistantServerRanking.Outcome? {
        switch probe {
        case .cancelled: return nil
        case .failed: return .unreachable
        case .timedOut: return .timedOut
        case .info(let info):
            guard info.serverID == server.address.serverID else { return .mismatch }
            guard info.schemaVersion >= MusicAssistantClient.minimumSchemaVersion,
                info.minSupportedSchemaVersion <= MusicAssistantClient.supportedSchemaVersion
            else { return .schemaUnsupported }
            return .reachable
        }
    }

    /// The fetch raced against the timeout on the injected clock.
    private static func probe(
        _ url: URL, fetch: @escaping InfoFetcher, sleep: @escaping @Sendable (Duration) async throws -> Void, timeout: Duration
    ) async -> Probe {
        await withTaskGroup(of: Probe.self) { group in
            group.addTask {
                do { return .info(try await fetch(url)) } catch { return Task.isCancelled ? .cancelled : .failed }
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                    return .timedOut
                } catch { return .cancelled }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return Task.isCancelled ? .cancelled : first
        }
    }
}
