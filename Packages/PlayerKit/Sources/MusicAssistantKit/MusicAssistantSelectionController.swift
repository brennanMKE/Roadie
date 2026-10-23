import Foundation
import Observation
import os

public enum WiFiAuthorization: Hashable, Sendable { case notDetermined, denied, restricted, authorized }

/// The current Wi-Fi network name. Reading never prompts; only `requestAuthorization()` may.
@MainActor public protocol WiFiNetworkProvider: AnyObject {
    var authorization: WiFiAuthorization { get }
    /// nil without permission, without Wi-Fi, or when the system returns nil. Never logged.
    func currentSSID() -> String?
    /// Called only from a user action. Returns the resulting authorization.
    func requestAuthorization() async -> WiFiAuthorization
}

/// Network path changes. The current path when monitoring starts is not a change and is not yielded.
public protocol NetworkChangeSource: Sendable {
    func changes() -> AsyncStream<Void>
}

/// Owns the automatic choice of Music Assistant server (#0075): the current winner, the "why" text for the UI, the
/// triggers (first use, network changes, Settings edits, a dropped server), the debounce and the cancellation.
///
/// Nothing happens at launch: `start()` only subscribes. The first probe runs when something asks for the server
/// (the Library connecting, #0067's probe); network changes act only after that. The Wi-Fi name is read only when
/// authorized, and permission is never requested here. Logs carry counts and kinds only, never a name, an address,
/// a network name or a server id.
@MainActor @Observable
public final class MusicAssistantSelectionController {
    public private(set) var current: MusicAssistantServerRanking.Candidate?
    /// "Home — on network X" etc. User data: UI only, never logged.
    public private(set) var reasonText: String = MusicAssistantServerRanking.notCheckedText
    /// The Library subtitle's server name (#0124): a real name with several servers, else nil. UI only, never logged.
    public private(set) var libraryName: String?
    /// The last probe round's outcomes, for the Settings status dots.
    public private(set) var lastOutcomes: [UUID: MusicAssistantServerRanking.Outcome] = [:]
    public var isResolving: Bool { resolving > 0 }
    /// A resolution has decided at least once (a winner or none).
    public private(set) var hasDecision = false
    /// For the Library subtitle and Settings › Library: nil before the first decision when nothing is resolving,
    /// "Finding a server…" while the first one runs, then `reasonText`.
    public var statusText: String? {
        if hasDecision { return reasonText }
        return isResolving ? MusicAssistantServerRanking.checkingText : nil
    }
    /// Called once per change of the winner's identity (id, address, server id).
    @ObservationIgnored public var onChange:
        (@MainActor (_ old: MusicAssistantServerConfiguration?, _ new: MusicAssistantServerConfiguration?) -> Void)?

    private var resolving = 0
    @ObservationIgnored private let store: MusicAssistantServerStore
    @ObservationIgnored private let active: MusicAssistantActiveServer
    @ObservationIgnored private let selector: MusicAssistantServerSelector
    @ObservationIgnored private let wifi: any WiFiNetworkProvider
    @ObservationIgnored private let network: any NetworkChangeSource
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var hasResolvedOnce = false
    /// The stored list the last resolution ranked; a later list differing only in names needs no re-check.
    @ObservationIgnored private var resolvedServers: [MusicAssistantServerConfiguration]?
    /// For tests: resolutions started and network changes received.
    @ObservationIgnored private(set) var resolutionCount = 0
    @ObservationIgnored private(set) var networkChangesSeen = 0
    /// `current` still stands: nothing invalidated it since the last resolution.
    @ObservationIgnored private var isValid = false
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "MusicAssistantSelection")

    /// No I/O here.
    public init<C: Clock>(
        store: MusicAssistantServerStore, active: MusicAssistantActiveServer, selector: MusicAssistantServerSelector,
        wifi: any WiFiNetworkProvider, network: any NetworkChangeSource, clock: C, debounce: Duration = .seconds(2)
    ) where C.Duration == Duration {
        self.store = store
        self.active = active
        self.selector = selector
        self.wifi = wifi
        self.network = network
        self.sleep = { try await clock.sleep(for: $0) }
        self.debounce = debounce
    }

    // MARK: Triggers

    /// Subscribes to network changes. No probe, no Wi-Fi read.
    public func start() {
        guard changesTask == nil else { return }
        let stream = network.changes()
        changesTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.networkChanged()
            }
        }
    }

    public func stop() {
        changesTask?.cancel()
        changesTask = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// The backend's `ServerProvider`: the cached winner while nothing invalidated it, else a fresh resolution.
    public func currentOrResolve() async -> MusicAssistantServerConfiguration? {
        if isValid, let current { return current.server }
        return await resolveNow()
    }

    /// Probes now. #0067's probe and Check Now call this.
    @discardableResult
    public func resolveNow() async -> MusicAssistantServerConfiguration? {
        hasResolvedOnce = true
        resolutionCount += 1
        let servers = store.load()
        resolvedServers = servers
        let ssid = wifi.authorization == .authorized ? wifi.currentSSID() : nil
        let candidates = MusicAssistantServerRanking.candidates(servers, ssid: ssid)
        resolving += 1
        let result = await selector.resolve(candidates)
        resolving -= 1
        // Undecided means a newer resolution with other candidates cancelled this one: that one decides.
        guard result.decision != .undecided else { return current?.server }
        apply(result, hasCandidates: !candidates.isEmpty)
        return current?.server
    }

    /// The settings hook: a list that differs from the last resolution's only in names relabels `current` and the
    /// reason without a probe (a rename never changes which server it is); any other edit goes to `serversChanged()`.
    public func serversEdited() {
        let servers = store.load()
        if hasResolvedOnce, let resolvedServers, Self.ignoringNames(servers) == Self.ignoringNames(resolvedServers) {
            self.resolvedServers = servers
            relabel(from: servers)
            return
        }
        serversChanged()
    }

    /// The Mac woke or a list change that matters: invalidate, and re-resolve only if the choice was ever made.
    public func serversChanged() {
        isValid = false
        guard hasResolvedOnce else { return }
        schedule(after: nil)
    }

    /// The active server failed (client failure, browse failure): invalidate and resolve without debounce.
    public func activeServerDropped() {
        isValid = false
        schedule(after: nil)
    }

    /// Awaits a scheduled resolution (debounced or not), for tests.
    public func waitForPending() async {
        await pendingTask?.value
    }

    // MARK: Private

    private func networkChanged() {
        networkChangesSeen += 1
        isValid = false
        guard hasResolvedOnce else { return }
        schedule(after: debounce)
    }

    private static func ignoringNames(
        _ servers: [MusicAssistantServerConfiguration]
    ) -> [MusicAssistantServerConfiguration] {
        servers.map { var server = $0; server.name = ""; return server }
    }

    /// Picks up a renamed `current` from `servers`. No probe, no `onChange`, no log (the name is user data).
    private func relabel(from servers: [MusicAssistantServerConfiguration]) {
        guard let current, let updated = servers.first(where: { $0.id == current.server.id }),
              updated.sameIdentity(as: current.server), updated != current.server else { return }
        let candidate = MusicAssistantServerRanking.Candidate(server: updated, basis: current.basis)
        self.current = candidate
        reasonText = MusicAssistantServerRanking.reason(for: candidate)
        libraryName = MusicAssistantServerRanking.libraryLabel(for: updated, serverCount: servers.count)
        active.set(updated)
    }

    private func schedule(after delay: Duration?) {
        pendingTask?.cancel()
        let sleep = sleep
        pendingTask = Task { [weak self] in
            if let delay {
                do { try await sleep(delay) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            await self.resolveNow()
        }
    }

    private func apply(_ result: MusicAssistantServerSelector.Result, hasCandidates: Bool) {
        let old = current?.server
        let winner: MusicAssistantServerRanking.Candidate?
        if case .chosen(let candidate) = result.decision { winner = candidate } else { winner = nil }
        current = winner
        hasDecision = true
        lastOutcomes = result.outcomes
        reasonText = MusicAssistantServerRanking.reason(for: result.decision, hasCandidates: hasCandidates) ?? reasonText
        libraryName = MusicAssistantServerRanking.libraryLabel(
            for: winner?.server, serverCount: resolvedServers?.count ?? 0)
        isValid = true
        active.set(winner?.server)
        // A rename typed while the probe ran.
        relabel(from: store.load())
        let changed: Bool
        switch (old, winner?.server) {
        case (nil, nil): changed = false
        case (let a?, let b?): changed = !a.sameIdentity(as: b)
        default: changed = true
        }
        Self.log.info("decision \(winner == nil ? "none" : "chosen", privacy: .public), changed \(changed, privacy: .public)")
        if changed { onChange?(old, winner?.server) }
    }
}
