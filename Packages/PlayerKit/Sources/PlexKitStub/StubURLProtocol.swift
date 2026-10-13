import Foundation
import os

/// A `URLProtocol` that answers from a route table, for unit tests and later UI tests.
/// The table and the recordings are static (that is how `URLProtocol` works), so suites that
/// use it must run serialized.
public final class StubURLProtocol: URLProtocol {
    public struct Route: Sendable {
        public var method: String = "GET"
        /// "/library/sections"
        public var path: String
        /// Matched against `url.host` when non-nil; nil matches any host.
        public var host: String? = nil
        /// Matched as a subset of the request's query items.
        public var query: [String: String] = [:]
        /// Matched against `X-Plex-Container-Start` when non-nil.
        public var containerStart: Int?
        public var status: Int = 200
        public var headers: [String: String] = ["Content-Type": "application/json"]
        public var body: Data = Data()
        /// When set, the load fails with it instead of responding.
        public var error: URLError?
        /// Seconds to wait before answering, so a test can cancel a request that is in flight.
        public var delay: TimeInterval = 0
        /// When set, the route answers only this many matching requests and then stops matching,
        /// so a later route can take over without the test re-registering mid-flight.
        public var times: Int?

        public init(
            method: String = "GET", path: String, host: String? = nil, query: [String: String] = [:], containerStart: Int? = nil,
            status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data(), error: URLError? = nil, delay: TimeInterval = 0, times: Int? = nil
        ) {
            self.method = method
            self.path = path
            self.host = host
            self.query = query
            self.containerStart = containerStart
            self.status = status
            self.headers = headers
            self.body = body
            self.error = error
            self.delay = delay
            self.times = times
        }

        public static func json(_ fixture: PlexFixture, path: String, query: [String: String] = [:], containerStart: Int? = nil) throws -> Route {
            Route(path: path, query: query, containerStart: containerStart, body: try fixture.data)
        }
    }

    public struct RecordedRequest: Sendable {
        public var url: URL
        public var method: String
        public var headers: [String: String]
    }

    private struct Table {
        var routes: [Route] = []
        var recorded: [RecordedRequest] = []
    }

    /// Route tables keyed by session id. The static API uses the `""` key.
    private static let state = OSAllocatedUnfairLock(initialState: [String: Table]())

    /// Replaces the route table.
    public static func register(_ routes: [Route]) {
        state.withLock { $0[""] = Table(routes: routes, recorded: $0[""]?.recorded ?? []) }
    }

    /// Clears routes and recordings.
    public static func reset() {
        state.withLock { $0[""] = Table() }
    }

    /// Every request seen since `reset()`.
    ///
    /// A request is recorded when URLSession starts loading it, which can be after a cancelled
    /// `data(for:)` has already thrown. A test that counts requests after a cancel must hold the
    /// request in flight (`delay`) or make the next one impossible (a long interval), not sleep.
    public static var recorded: [RecordedRequest] {
        state.withLock { $0[""]?.recorded ?? [] }
    }

    /// Requests from a `Handle`'s session carry its id in this header; the stub strips it from recordings.
    public static let sessionHeader = "X-Stub-Session"

    /// An independent route table and recording. Suites that use handles can run in parallel
    /// with each other and with the static table.
    public struct Handle: Sendable {
        public let id: String
        public let session: URLSession

        public func register(_ routes: [Route]) {
            let id = id
            StubURLProtocol.state.withLock { $0[id] = Table(routes: routes, recorded: $0[id]?.recorded ?? []) }
        }

        /// Requests this handle's session has started loading; see the note on the static `recorded`.
        public var recorded: [RecordedRequest] {
            let id = id
            return StubURLProtocol.state.withLock { $0[id]?.recorded ?? [] }
        }

        public func reset() {
            let id = id
            StubURLProtocol.state.withLock { $0[id] = Table() }
        }
    }

    /// A new handle with its own table.
    public static func handle() -> Handle {
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [sessionHeader: id]
        state.withLock { $0[id] = Table() }
        return Handle(id: id, session: URLSession(configuration: configuration))
    }

    /// An ephemeral session whose only protocol is this stub.
    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let sessionID = request.value(forHTTPHeaderField: Self.sessionHeader) ?? ""
        let headers = (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != Self.sessionHeader.lowercased() }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = request.value(forHTTPHeaderField: "X-Plex-Container-Start").flatMap(Int.init)

        let route = Self.state.withLock { tables -> Route? in
            var table = tables[sessionID] ?? Table()
            table.recorded.append(RecordedRequest(url: url, method: method, headers: headers))
            tables[sessionID] = table
            let index = table.routes.firstIndex { route in
                (route.times ?? 1) > 0
                    && route.method == method
                    && route.path == url.path
                    && (route.host == nil || route.host == url.host)
                    && route.query.allSatisfy { key, value in items.contains { $0.name == key && $0.value == value } }
                    && (route.containerStart == nil || route.containerStart == start)
            }
            guard let index else { return nil }
            let matched = table.routes[index]
            if let times = matched.times {
                table.routes[index].times = times - 1
                tables[sessionID] = table
            }
            return matched
        }

        guard let route else {
            respond(url: url, status: 404, headers: [:], body: Data())
            return
        }
        let status = route.status, routeHeaders = route.headers, body = route.body, error = route.error
        let deliver: @Sendable (StubURLProtocol) -> Void = { stub in
            if let error {
                stub.client?.urlProtocol(stub, didFailWithError: error)
            } else {
                stub.respond(url: url, status: status, headers: routeHeaders, body: body)
            }
        }
        if route.delay > 0 {
            let stopped = self.stopped
            nonisolated(unsafe) let stub = self
            DispatchQueue.global().asyncAfter(deadline: .now() + route.delay) {
                if stopped.withLock({ $0 }) { return }
                deliver(stub)
            }
        } else {
            deliver(self)
        }
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    public override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private func respond(url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
