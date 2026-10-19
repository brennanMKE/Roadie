import Foundation
import os
@testable import MusicAssistantKit

/// `/info` answers by base URL for the selector. No network: each URL answers, fails, waits for `release()`, or
/// hangs until cancelled.
final class FakeInfo: @unchecked Sendable {
    enum Behavior {
        case answer(String, schema: Int = 65)
        case fail
        case gated(String)
        case hang
    }

    private struct State {
        var table: [URL: Behavior] = [:]
        var calls: [URL] = []
        var cancelled: [URL] = []
        var released = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [URL] { state.withLock { $0.calls } }
    var cancelled: [URL] { state.withLock { $0.cancelled } }

    func set(_ url: String, _ behavior: Behavior) {
        state.withLock { $0.table[URL(string: url)!] = behavior }
    }

    func release() { state.withLock { $0.released = true } }

    var fetcher: MusicAssistantServerSelector.InfoFetcher { { [self] in try await fetch($0) } }

    private func fetch(_ url: URL) async throws -> MAServerInfo {
        let behavior = state.withLock { s -> Behavior? in
            s.calls.append(url)
            return s.table[url]
        }
        switch behavior {
        case .answer(let id, let schema): return try Self.info(id, schema: schema)
        case .fail, nil: throw URLError(.cannotConnectToHost)
        case .gated(let id):
            try await waitUntil { self.state.withLock { $0.released } }
            return try Self.info(id)
        case .hang:
            try await waitUntil { false }
            throw CancellationError()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let url = state.withLock { $0.calls.last }
        do {
            while !condition() { try await Task.sleep(for: .milliseconds(2)) }
        } catch {
            state.withLock { if let url { $0.cancelled.append(url) } }
            throw error
        }
    }

    static func info(_ id: String, schema: Int = 65) throws -> MAServerInfo {
        let json = #"{"server_id":"\#(id)","schema_version":\#(schema),"min_supported_schema_version":24,"name":"Fake"}"#
        return try JSONDecoder().decode(MAServerInfo.self, from: Data(json.utf8))
    }
}

/// A Wi-Fi provider with counters.
@MainActor
final class StubWiFi: WiFiNetworkProvider {
    var authorization: WiFiAuthorization
    var ssid: String?
    /// What `requestAuthorization()` changes `authorization` to.
    var grant: WiFiAuthorization
    private(set) var ssidCalls = 0
    private(set) var authorizationRequests = 0

    init(_ authorization: WiFiAuthorization = .notDetermined, ssid: String? = nil, grant: WiFiAuthorization = .authorized) {
        self.authorization = authorization
        self.ssid = ssid
        self.grant = grant
    }

    func currentSSID() -> String? {
        ssidCalls += 1
        return authorization == .authorized ? ssid : nil
    }

    func requestAuthorization() async -> WiFiAuthorization {
        authorizationRequests += 1
        authorization = grant
        return grant
    }
}

/// Network changes on demand.
final class StubNetworkChanges: NetworkChangeSource, @unchecked Sendable {
    private let continuations = OSAllocatedUnfairLock(initialState: [AsyncStream<Void>.Continuation]())

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func change() {
        for continuation in continuations.withLock({ $0 }) { continuation.yield() }
    }
}

func makeServer(_ url: String, id: String, name: String, networks: [String]) -> MusicAssistantServerConfiguration {
    var server = makeServer(url, id: id, name: name)
    server.networks = networks
    return server
}
