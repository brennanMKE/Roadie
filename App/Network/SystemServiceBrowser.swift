import Foundation
import MusicAssistantKit
import Network
import os

/// `NWBrowser` behind `MusicAssistantServiceBrowser` (#0104). Browses `MusicAssistantDiscovery.serviceTypes`; a Home
/// Assistant TXT record gives the host directly, otherwise the endpoint is resolved by opening (and at once
/// cancelling) a TCP connection. Nothing is sent. Logs never carry names, endpoints or TXT values.
struct SystemServiceBrowser: MusicAssistantServiceBrowser {
    func hosts() -> AsyncStream<MusicAssistantDiscoveredHost> {
        let (stream, continuation) = AsyncStream<MusicAssistantDiscoveredHost>.makeStream(bufferingPolicy: .unbounded)
        let box = BrowserBox { continuation.yield($0) }
        box.start()
        continuation.onTermination = { _ in box.cancel() }
        return stream
    }

    /// A resolved endpoint as a discovered host; IPv6 and non-host-port endpoints give nil (#0216).
    static func host(of endpoint: NWEndpoint?, type: String) -> MusicAssistantDiscoveredHost? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let name: String
        switch host {
        case .ipv4(let address): name = address.rawValue.map(String.init).joined(separator: ".")
        case .name(let n, _): name = n
        default: return nil  // IPv6 skipped
        }
        return MusicAssistantDiscoveredHost(
            host: name, port: MusicAssistantDiscovery.port(forServiceType: type, advertised: Int(port.rawValue)))
    }
}

/// Owns the browsers and pending connections; their state is touched only on `queue`.
private final class BrowserBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.sstools.roadie.bonjour")
    private let log = Logger(subsystem: "co.sstools.roadie", category: "MusicAssistantDiscovery")
    private let yield: @Sendable (MusicAssistantDiscoveredHost) -> Void
    private var browsers: [NWBrowser] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var cancelled = false

    init(yield: @escaping @Sendable (MusicAssistantDiscoveredHost) -> Void) {
        self.yield = yield
    }

    func start() {
        queue.async { [self] in
            for type in MusicAssistantDiscovery.serviceTypes {
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
                browser.stateUpdateHandler = { [self] state in
                    if case .failed(let error) = state { log.info("browser failed \(error.errorCode, privacy: .public)") }
                }
                browser.browseResultsChangedHandler = { [self] _, changes in
                    for change in changes {
                        if case .added(let result) = change { found(result, type: type) }
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            for browser in browsers { browser.cancel() }
            browsers = []
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    private func found(_ result: NWBrowser.Result, type: String) {
        guard !cancelled else { return }
        if MusicAssistantDiscovery.readsHostFromTXT(serviceType: type), case .bonjour(let txt) = result.metadata,
            let host = MusicAssistantDiscovery.host(fromTXT: txt.dictionary)
        {
            yield(MusicAssistantDiscoveredHost(host: host))
            return
        }
        resolve(result.endpoint, type: type)
    }

    private func resolve(_ endpoint: NWEndpoint, type: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let endpoint = connection.currentPath?.remoteEndpoint
                if let host = SystemServiceBrowser.host(of: endpoint, type: type) { yield(host) }
                finish(key)
            case .failed, .waiting:
                finish(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish(key) }
    }

    private func finish(_ key: ObjectIdentifier) {
        guard let connection = connections.removeValue(forKey: key) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
