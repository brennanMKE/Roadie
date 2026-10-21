import Foundation
import MusicAssistantKit
import os

/// Answers `GET /info`, `GET /api-docs/commands.json` (#0137) and the image proxy from recorded values; records every request so tests can assert
/// the exact path and that no credentials were sent.
public final class StubHTTPTransport: MAHTTPTransport, @unchecked Sendable {
    public struct Request: Sendable, Hashable {
        public var url: URL
        public var headers: [String: String]
    }

    private enum Outcome: Sendable {
        case response(MAHTTPResponse)
        case failure(URLError.Code)
    }

    private struct State {
        var requests: [Request] = []
        var overrides: [(prefix: String, outcome: Outcome)] = []
    }

    /// A 1x1 PNG.
    public static let imageBytes = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") ?? Data()

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var requests: [Request] { state.withLock { $0.requests } }

    /// Requests whose path starts with `pathPrefix` get this response (latest override first).
    public func setResponse(pathPrefix: String, _ response: MAHTTPResponse) {
        state.withLock { $0.overrides.insert((prefix: pathPrefix, outcome: Outcome.response(response)), at: 0) }
    }

    public func setFailure(pathPrefix: String, code: URLError.Code) {
        state.withLock { $0.overrides.insert((prefix: pathPrefix, outcome: Outcome.failure(code)), at: 0) }
    }

    public func get(_ url: URL, headers: [String: String], timeout: Duration) async throws -> MAHTTPResponse {
        let override = state.withLock { s -> Outcome? in
            s.requests.append(Request(url: url, headers: headers))
            return s.overrides.first { url.path.hasPrefix($0.prefix) }?.outcome
        }
        switch override {
        case .response(let response)?: return response
        case .failure(let code)?: throw URLError(code)
        case nil: break
        }
        if url.path == "/info" {
            return MAHTTPResponse(status: 200, contentType: "application/json", body: try MAFixture.infoHTTP.data)
        }
        if url.path.hasSuffix("/api-docs/commands.json") {
            return MAHTTPResponse(status: 200, contentType: "application/json", body: try Self.commandNames())
        }
        if url.path.hasPrefix("/imageproxy/") {
            let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "size" }?.value
            if size == "200" {
                let body = "Unsupported size 200: must be one of 0, 80, 160, 256, 512, 1024 (0 = original size)."
                return MAHTTPResponse(status: 400, contentType: "text/plain", body: Data(body.utf8))
            }
            return MAHTTPResponse(status: 200, contentType: "image/jpeg", body: Self.imageBytes)
        }
        return MAHTTPResponse(status: 404, contentType: "text/plain", body: Data())
    }

    /// `commands-names.json`: the recorded server's `commands.json` trimmed to the `command` field.
    public static func commandNames() throws -> Data {
        guard let url = Bundle.module.url(forResource: "commands-names", withExtension: "json", subdirectory: "Fixtures") else {
            throw MAFixture.Missing(name: "commands-names")
        }
        return try Data(contentsOf: url)
    }
}
