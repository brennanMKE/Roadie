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
        /// Matched as a subset of the request's query items.
        public var query: [String: String] = [:]
        /// Matched against `X-Plex-Container-Start` when non-nil.
        public var containerStart: Int?
        public var status: Int = 200
        public var headers: [String: String] = ["Content-Type": "application/json"]
        public var body: Data = Data()
        /// When set, the load fails with it instead of responding.
        public var error: URLError?

        public init(
            method: String = "GET", path: String, query: [String: String] = [:], containerStart: Int? = nil,
            status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data(), error: URLError? = nil
        ) {
            self.method = method
            self.path = path
            self.query = query
            self.containerStart = containerStart
            self.status = status
            self.headers = headers
            self.body = body
            self.error = error
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
            return table.routes.first { route in
                route.method == method
                    && route.path == url.path
                    && route.query.allSatisfy { key, value in items.contains { $0.name == key && $0.value == value } }
                    && (route.containerStart == nil || route.containerStart == start)
            }
        }

        guard let route else {
            respond(url: url, status: 404, headers: [:], body: Data())
            return
        }
        if let error = route.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        respond(url: url, status: route.status, headers: route.headers, body: route.body)
    }

    public override func stopLoading() {}

    private func respond(url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
