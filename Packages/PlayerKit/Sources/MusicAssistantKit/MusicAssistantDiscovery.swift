import Foundation
import Observation
import os

/// A host found on the network (#0104). `port` nil means Music Assistant's default (8095), as for a Home Assistant host.
public struct MusicAssistantDiscoveredHost: Hashable, Sendable {
    public var host: String
    public var port: Int?

    public init(host: String, port: Int? = nil) {
        self.host = host
        self.port = port
    }
}

/// Bonjour behind a protocol (#0104). Browsing stops when the stream terminates. Yields each host once per browse;
/// never logs names or addresses.
public protocol MusicAssistantServiceBrowser: Sendable {
    func hosts() -> AsyncStream<MusicAssistantDiscoveredHost>
}

/// A Music Assistant server found on the network that is not configured yet. `id` is its `server_id`. User data: UI
/// only, never logged.
public struct MusicAssistantDiscoveredServer: Identifiable, Hashable, Sendable {
    public var id: String
    public var url: URL
    public var name: String?

    public init(id: String, url: URL, name: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
    }

    /// `name`, or the host when the name is generic. UI only, never logged.
    public var displayName: String { MusicAssistantServerConfiguration.displayName(name, host: url.host()) }
}

public enum MusicAssistantDiscovery {
    /// Home Assistant (the add-on serves Music Assistant on the same host), Music Assistant itself should it ever
    /// advertise, and Sendspin, which a Music Assistant server advertises (finds standalone installs).
    public static let serviceTypes = ["_home-assistant._tcp", "_music-assistant._tcp", "_sendspin-server._tcp"]
    public static let wellKnownHosts = ["homeassistant.local"]

    /// The Music Assistant port for a host found through `serviceType`: the advertised port only for
    /// `_music-assistant._tcp`; nil (8095) for the others, whose advertised port is another service's.
    public static func port(forServiceType serviceType: String, advertised: Int?) -> Int? {
        serviceType == "_music-assistant._tcp" ? advertised : nil
    }

    /// Whether the host comes from the TXT record (`internal_url` / `base_url`) before resolving the endpoint.
    public static func readsHostFromTXT(serviceType: String) -> Bool { serviceType == "_home-assistant._tcp" }

    /// `http://host:port`, port default 8095. Lowercased, a trailing dot dropped, IPv6 bracketed. nil for a host ATS
    /// does not treat as local, a scoped IPv6 (`%`), or an empty host.
    public static func baseURL(for found: MusicAssistantDiscoveredHost) -> URL? {
        var host = found.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains("%"), MusicAssistantAddressInput.isLocalHost(host) else { return nil }
        let port = found.port ?? MusicAssistantAddressInput.defaultPort
        guard (1...65535).contains(port) else { return nil }
        return URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }

    /// Home Assistant's TXT record: the host of `internal_url`, else of `base_url`. nil when neither parses to a
    /// local host.
    public static func host(fromTXT txt: [String: String]) -> String? {
        for key in ["internal_url", "base_url"] {
            guard let value = txt[key], let url = URL(string: value), let host = url.host(percentEncoded: false) else { continue }
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if !bare.isEmpty, MusicAssistantAddressInput.isLocalHost(bare) { return bare }
        }
        return nil
    }
}

private let log = Logger(subsystem: "co.sstools.roadie", category: "MusicAssistantDiscovery")

/// Finds Music Assistant servers on the current network (#0104) while someone is looking: `start()`/`stop()` are
/// reference-counted and nothing runs before the first `start()`. Probes `/info` unauthenticated (the fetcher takes a
/// URL only, so no token can be sent). Logs carry counts only.
@MainActor @Observable
public final class MusicAssistantDiscoveryModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Purpose {
        case discovered(order: Int)
        /// A configured server answered at `newURL`; this probes its stored address.
        case storedCheck(id: UUID, serverID: String, newURL: URL)
    }

    private struct Found {
        var order: Int
        var server: MusicAssistantDiscoveredServer
    }

    @ObservationIgnored private let store: MusicAssistantServerStore
    @ObservationIgnored private let browser: any MusicAssistantServiceBrowser
    @ObservationIgnored private let fetch: MusicAssistantServerSelector.InfoFetcher
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let probeTimeout: Duration

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var probeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var probed: Set<URL> = []
    @ObservationIgnored private var found: [Found] = []
    @ObservationIgnored private var moveChecked: Set<UUID> = []
    @ObservationIgnored private var answered = 0
    @ObservationIgnored private var moved = 0

    public private(set) var offers: [MusicAssistantDiscoveredServer] = []
    /// True while any probe is in flight.
    public private(set) var isSearching = false
    /// A search ran to idle at least once since the last `start()`.
    public private(set) var hasSearched = false

    /// A configured server answered at another address and its stored address did not answer as it.
    @ObservationIgnored public var onConfiguredServerMoved: (@MainActor (_ id: UUID, _ serverID: String, _ url: URL) -> Void)?

    /// No I/O here.
    public init(
        store: MusicAssistantServerStore, browser: any MusicAssistantServiceBrowser,
        fetch: @escaping MusicAssistantServerSelector.InfoFetcher, clock: any Clock<Duration> = ContinuousClock(),
        probeTimeout: Duration = .seconds(3)
    ) {
        self.store = store
        self.browser = browser
        self.fetch = fetch
        self.sleep = { try await clock.sleep(for: $0) }
        self.probeTimeout = probeTimeout
    }

    public nonisolated var description: String { "MusicAssistantDiscoveryModel(redacted)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: []) }

    public func start() {
        users += 1
        guard users == 1 else { return }
        beginSearch()
    }

    /// Starts a fresh search for whoever already called `start()`; does nothing when no one has, or while a search is
    /// running.
    public func searchAgain() {
        guard users > 0, !isSearching else { return }
        browseTask?.cancel()
        browseTask = nil
        for task in probeTasks.values { task.cancel() }
        probeTasks = [:]
        beginSearch()
    }

    private func beginSearch() {
        generation += 1
        probed = []
        found = []
        offers = []
        moveChecked = []
        answered = 0
        moved = 0
        hasSearched = false
        log.info("discovery started")
        for host in MusicAssistantDiscovery.wellKnownHosts { consider(MusicAssistantDiscoveredHost(host: host)) }
        let stream = browser.hosts()
        let gen = generation
        browseTask = Task { [weak self] in
            for await host in stream {
                guard let self, self.generation == gen else { return }
                self.consider(host)
            }
        }
    }

    public func stop() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        generation += 1
        browseTask?.cancel()
        browseTask = nil
        for task in probeTasks.values { task.cancel() }
        probeTasks = [:]
        isSearching = false
        log.info("discovery stopped")
    }

    /// Recomputes `offers`: found servers minus those whose id or address is already stored.
    public func refreshOffers() {
        let stored = store.load()
        offers = found.sorted { $0.order < $1.order }.map(\.server).filter { server in
            !stored.contains { $0.address.serverID == server.id || $0.address.baseURL == server.url }
        }
    }

    /// Awaits the outstanding probes, for tests.
    public func waitForIdle() async {
        while let task = probeTasks.values.first { await task.value }
    }

    // MARK: Private

    private func consider(_ host: MusicAssistantDiscoveredHost) {
        guard let url = MusicAssistantDiscovery.baseURL(for: host), probed.insert(url).inserted else { return }
        launchProbe(url, purpose: .discovered(order: probed.count))
    }

    private func launchProbe(_ url: URL, purpose: Purpose) {
        let id = UUID()
        let gen = generation
        let fetch = fetch
        let sleep = sleep
        let timeout = probeTimeout
        isSearching = true
        probeTasks[id] = Task { [weak self] in
            let info = await Self.probe(url, fetch: fetch, sleep: sleep, timeout: timeout)
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            self.probeTasks[id] = nil
            self.handle(info, at: url, purpose: purpose)
            if self.probeTasks.isEmpty {
                self.isSearching = false
                self.hasSearched = true
                log.info(
                    "idle: \(self.probed.count) probed, \(self.answered) answered, \(self.offers.count) offered, \(self.moved) moved")
            }
        }
    }

    private func handle(_ info: MAServerInfo?, at url: URL, purpose: Purpose) {
        switch purpose {
        case .storedCheck(let id, let serverID, let newURL):
            guard info?.serverID != serverID else { return }
            moved += 1
            onConfiguredServerMoved?(id, serverID, newURL)
        case .discovered(let order):
            guard let info else { return }
            answered += 1
            let stored = store.load()
            if stored.contains(where: { $0.address.baseURL == url }) { return }
            let same = stored.filter { $0.address.serverID == info.serverID }
            if !same.isEmpty {
                guard same.count == 1, let server = same.first, server.address.baseURL.scheme?.lowercased() == "http",
                    !MusicAssistantServerRanking.isTailscale(server.address.baseURL), moveChecked.insert(server.id).inserted
                else { return }
                launchProbe(server.address.baseURL, purpose: .storedCheck(id: server.id, serverID: info.serverID, newURL: url))
                return
            }
            let server = MusicAssistantDiscoveredServer(id: info.serverID, url: url, name: info.name)
            if let index = found.firstIndex(where: { $0.server.id == info.serverID }) {
                if order < found[index].order { found[index] = Found(order: order, server: server) }
            } else {
                found.append(Found(order: order, server: server))
            }
            refreshOffers()
        }
    }

    /// The fetch raced against the timeout on the injected clock (as `MusicAssistantServerSelector`'s probe). nil for
    /// an error, a timeout or a cancellation.
    private nonisolated static func probe(
        _ url: URL, fetch: @escaping MusicAssistantServerSelector.InfoFetcher,
        sleep: @escaping @Sendable (Duration) async throws -> Void, timeout: Duration
    ) async -> MAServerInfo? {
        await withTaskGroup(of: MAServerInfo?.self) { group in
            group.addTask { try? await fetch(url) }
            group.addTask {
                try? await sleep(timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return Task.isCancelled ? nil : first
        }
    }
}
