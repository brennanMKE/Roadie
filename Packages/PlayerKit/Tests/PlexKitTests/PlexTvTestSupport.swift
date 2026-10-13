import Foundation
import Testing
import PlexKit
import PlexKitStub

/// Shared by the plex.tv sign-in suites. Everything here is fake: the PIN code and the token come from
/// the hand-written fixtures under `Fixtures/plextv/`.
enum PlexTv {
    static let identifier = "11111111-2222-3333-4444-555555555555"
    static let base = URL(string: "https://stub.plex.tv")!
    static let machine = "0123456789abcdef0123456789abcdef01234567"

    /// The fake token, read from the claimed fixture so it is typed once (in the JSON).
    static var fakeToken: String {
        get throws {
            let object = try #require(try JSONSerialization.jsonObject(with: PlexFixture.pinClaimed.data) as? [String: Any])
            return try #require(object["authToken"] as? String)
        }
    }

    static func account(_ handle: StubURLProtocol.Handle) -> PlexAccountClient {
        PlexAccountClient(clientIdentifier: identifier, baseURL: base, session: handle.session)
    }

    static func createRoute(_ fixture: PlexFixture = .pinCreated, status: Int = 201) throws -> StubURLProtocol.Route {
        .init(method: "POST", path: "/api/v2/pins", status: status, body: try fixture.data)
    }

    static func pollRoute(_ fixture: PlexFixture = .pinCreated, status: Int = 200, error: URLError? = nil, delay: TimeInterval = 0, times: Int? = nil) throws -> StubURLProtocol.Route {
        .init(path: "/api/v2/pins/123456789", status: status, body: try fixture.data, error: error, delay: delay, times: times)
    }

    static func resourcesRoute(body: Data? = nil, status: Int = 200) throws -> StubURLProtocol.Route {
        .init(path: "/api/v2/resources", status: status, body: try body ?? PlexFixture.resources.data)
    }

    /// The resources fixture with only the first (owned) server kept.
    static func ownedServerOnly() throws -> Data {
        let list = try #require(try JSONSerialization.jsonObject(with: PlexFixture.resources.data) as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: [list[0]])
    }

    static func isPoll(_ request: StubURLProtocol.RecordedRequest) -> Bool {
        request.method == "GET" && request.url.path.hasPrefix("/api/v2/pins/")
    }

    static func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    /// Polls `condition` every 10 ms until it holds or `seconds` pass.
    @discardableResult
    static func wait(seconds: Double = 5, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Stands in for `NSWorkspace.shared.open`: records the URLs and answers with a canned result.
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var result: Bool

    init(result: Bool = true) { self.result = result }

    var opened: [URL] { lock.withLock { urls } }

    func record(_ url: URL) -> Bool {
        lock.withLock { urls.append(url) }
        return result
    }

    var opener: PlexPinSignIn.URLOpener {
        { [self] url in record(url) }
    }
}
