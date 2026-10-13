import Foundation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "PlexServerResolver")

/// Finds the connection of a server that actually answers from here.
public struct PlexServerResolver: Sendable {
    public var clientIdentifier: String
    public var product: String
    public var version: String
    /// Per probe.
    public var timeout: TimeInterval
    public var session: URLSession

    public init(
        clientIdentifier: String, product: String = "SkinAmp", version: String = "0.1.0",
        timeout: TimeInterval = 5, session: URLSession = .shared
    ) {
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.timeout = timeout
        self.session = session
    }

    /// Probes `resource.rankedConnections` in parallel with GET /identity (no token). Returns the
    /// best-ranked connection whose machineIdentifier equals `resource.clientIdentifier`, or nil.
    public func reachableConnection(of resource: PlexResource) async -> PlexResourceConnection? {
        let ranked = resource.rankedConnections
        let expected = resource.clientIdentifier
        let probes = ranked.enumerated().compactMap { index, connection in
            connection.url.map { (index, $0) }
        }
        let best = await withTaskGroup(of: Int?.self, returning: Int?.self) { group in
            for (index, url) in probes {
                let client = PlexClient(
                    baseURL: url, token: nil, clientIdentifier: clientIdentifier, product: product,
                    version: version, timeout: timeout, session: session)
                group.addTask {
                    guard let identity = try? await client.identity(), identity.machineIdentifier == expected else { return nil }
                    return index
                }
            }
            var best: Int?
            for await index in group {
                if let index, best == nil || index < best! { best = index }
            }
            return best
        }
        if Task.isCancelled {
            log.info("server: cancelled")
            return nil
        }
        guard let best else {
            log.info("server: none reachable")
            return nil
        }
        let connection = ranked[best]
        log.info("server: resolved \(connection.tier.name, privacy: .public), rank \(best + 1) of \(ranked.count)")
        return connection
    }
}
