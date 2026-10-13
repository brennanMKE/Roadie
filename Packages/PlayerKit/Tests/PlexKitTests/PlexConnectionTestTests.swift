import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexConnectionTestTests {
    static let secret = "tok-UNIT-TEST-SECRET-0123"
    static let identifier = "11111111-2222-3333-4444-555555555555"
    let token = PlexToken(PlexConnectionTestTests.secret)

    private func make() -> (StubURLProtocol.Handle, PlexConnectionTest) {
        let handle = StubURLProtocol.handle()
        return (handle, PlexConnectionTest(clientIdentifier: Self.identifier, session: handle.session))
    }

    private func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    private func failure(_ test: PlexConnectionTest, address: String = "stub.local") async -> PlexConnectionFailure? {
        do {
            _ = try await test.run(address: address, token: token)
            return nil
        } catch let failure as PlexConnectionFailure {
            return failure
        } catch {
            return nil
        }
    }

    private func delayed(_ route: StubURLProtocol.Route, _ seconds: TimeInterval) -> StubURLProtocol.Route {
        var route = route
        route.delay = seconds
        return route
    }

    private func okRoutes() throws -> [StubURLProtocol.Route] {
        [try .json(.identity, path: "/identity"), try .json(.sections, path: "/library/sections")]
    }

    private func route(path: String, status: Int, contentType: String = "text/html") -> StubURLProtocol.Route {
        .init(path: path, status: status, headers: ["Content-Type": contentType], body: Data("<html></html>".utf8))
    }

    private func fixtureSections() throws -> [PlexLibrarySection] {
        let object = try #require(try JSONSerialization.jsonObject(with: PlexFixture.sections.data) as? [String: Any])
        let container = try #require(object["MediaContainer"] as? [String: Any])
        let directories = try #require(container["Directory"] as? [[String: Any]])
        return directories.compactMap { d in
            guard let key = d["key"] as? String, let title = d["title"] as? String, let type = d["type"] as? String else { return nil }
            return PlexLibrarySection(key: key, title: title, type: type)
        }
    }

    private func sectionsRoute(dropping: (String) -> Bool) throws -> StubURLProtocol.Route {
        var object = try #require(try JSONSerialization.jsonObject(with: PlexFixture.sections.data) as? [String: Any])
        var container = try #require(object["MediaContainer"] as? [String: Any])
        let directories = try #require(container["Directory"] as? [[String: Any]])
        container["Directory"] = directories.filter { !dropping($0["type"] as? String ?? "") }
        object["MediaContainer"] = container
        return .init(path: "/library/sections", body: try JSONSerialization.data(withJSONObject: object))
    }

    @Test func successReturnsIdentityAndMusicSections() async throws {
        let (handle, test) = make()
        handle.register(try okRoutes())
        let connection = try await test.run(address: "stub.local", token: token)
        #expect(connection.identity.machineIdentifier == "0123456789abcdef0123456789abcdef01234567")
        #expect(connection.musicSections.map(\.key) == (try fixtureSections()).filter(\.isMusic).map(\.key))
        #expect(!connection.musicSections.isEmpty)
        #expect(connection.baseURL.absoluteString == "http://stub.local:32400")
        #expect(!String(reflecting: connection).contains(Self.secret))
    }

    @Test func identityIsRequestedWithoutTheTokenAndSectionsWithIt() async throws {
        let (handle, test) = make()
        handle.register(try okRoutes())
        _ = try await test.run(address: "stub.local", token: token)
        let recorded = handle.recorded
        #expect(recorded.count == 2)
        #expect(recorded[0].url.path == "/identity")
        #expect(header(recorded[0], "X-Plex-Token") == nil)
        #expect(recorded[1].url.path == "/library/sections")
        #expect(header(recorded[1], "X-Plex-Token") == Self.secret)
    }

    @Test func invalidAddressFailsBeforeAnyRequest() async {
        let (handle, test) = make()
        let result = await failure(test, address: "ftp://joe")
        #expect(result == .invalidAddress)
        #expect(handle.recorded.isEmpty)
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed])
    func transportErrorsAreUnreachable(code: URLError.Code) async throws {
        let (handle, test) = make()
        handle.register([.init(path: "/identity", error: URLError(code))])
        let result = await failure(test)
        #expect(result == .unreachable(.transport(code)))
        #expect(handle.recorded.count == 1)
        #expect(!String(describing: result).contains(Self.secret))
    }

    @Test func cancelledTransportIsCancelled() async {
        let (handle, test) = make()
        handle.register([.init(path: "/identity", error: URLError(.cancelled))])
        #expect(await failure(test) == .cancelled)
        #expect(handle.recorded.count == 1)
    }

    @Test func cancellingTheTaskIsCancelled() async throws {
        let (handle, test) = make()
        handle.register([delayed(try .json(.identity, path: "/identity"), 1), try .json(.sections, path: "/library/sections")])
        let address = "stub.local"
        let token = self.token
        let task = Task { () async -> PlexConnectionFailure? in
            do throws(PlexConnectionFailure) {
                _ = try await test.run(address: address, token: token)
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .seconds(0.2))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(!handle.recorded.contains { $0.url.path == "/library/sections" })
    }

    @Test func nonPlexServerIsUnreachable() async {
        for (status, contentType, expected) in [
            (200, "text/html", PlexError.notJSON(contentType: "text/html")),
            (404, "text/html", PlexError.notFound),
            (500, "text/html", PlexError.httpStatus(500)),
        ] {
            let (handle, test) = make()
            handle.register([route(path: "/identity", status: status, contentType: contentType)])
            #expect(await failure(test) == .unreachable(expected))
            #expect(handle.recorded.count == 1)
        }
    }

    @Test func rejectedTokenIsUnauthorized() async throws {
        let (handle, test) = make()
        handle.register([try .json(.identity, path: "/identity"), route(path: "/library/sections", status: 401)])
        #expect(await failure(test) == .unauthorized)
        #expect(header(handle.recorded[1], "X-Plex-Token") == Self.secret)
    }

    @Test func forbiddenIsUnauthorized() async throws {
        let (handle, test) = make()
        handle.register([try .json(.identity, path: "/identity"), route(path: "/library/sections", status: 403)])
        #expect(await failure(test) == .unauthorized)
    }

    @Test func sectionsTransportErrorIsUnreachable() async throws {
        let (handle, test) = make()
        handle.register([try .json(.identity, path: "/identity"),
                         .init(path: "/library/sections", error: URLError(.networkConnectionLost))])
        #expect(await failure(test) == .unreachable(.transport(.networkConnectionLost)))
    }

    @Test func noArtistSectionIsNoMusicLibrary() async throws {
        let (handle, test) = make()
        handle.register([try .json(.identity, path: "/identity"), try sectionsRoute { $0 == "artist" }])
        #expect(await failure(test) == .noMusicLibrary)

        let (emptyHandle, emptyTest) = make()
        emptyHandle.register([try .json(.identity, path: "/identity"), try sectionsRoute { _ in true }])
        #expect(await failure(emptyTest) == .noMusicLibrary)
    }

    @Test func messagesMatchTheDoc() {
        let cases: [(PlexConnectionFailure, String)] = [
            (.invalidAddress, "The server address is not valid."),
            (.unreachable(.notFound), "Can't reach the server. Check the address, and whether you're on the home network or Tailscale."),
            (.unauthorized, "Signed in, but this account can't access this server."),
            (.noMusicLibrary, "This server has no music library."),
            (.cancelled, "The connection test was cancelled."),
        ]
        for (failure, text) in cases {
            #expect(failure.message == text)
            #expect(failure.errorDescription == text)
            #expect(failure.localizedDescription == text)
        }
        #expect(PlexConnectionFailure.invalidAddress.message == PlexError.invalidBaseURL.errorDescription)
        #expect(PlexConnectionFailure.unreachable(.notFound).underlying == .notFound)
        #expect(PlexConnectionFailure.unauthorized.underlying == nil)
        #expect(PlexConnectionFailure.cancelled.underlying == nil)
    }

    @Test func failuresNeverContainTheToken() async throws {
        var failures: [PlexConnectionFailure] = [.invalidAddress, .unauthorized, .noMusicLibrary, .cancelled]
        let (handle, test) = make()
        handle.register([.init(path: "/identity", error: URLError(.timedOut))])
        if let f = await failure(test) { failures.append(f) }
        let (h2, t2) = make()
        h2.register([try .json(.identity, path: "/identity"), route(path: "/library/sections", status: 401)])
        if let f = await failure(t2) { failures.append(f) }
        for f in failures {
            for text in [String(describing: f), String(reflecting: f), f.localizedDescription] {
                #expect(!text.contains(Self.secret))
            }
        }
    }

    @Test func requestsUseTheNormalizedBase() async throws {
        let (handle, test) = make()
        handle.register(try okRoutes())
        _ = try await test.run(address: "  Stub.Local/ ", token: token)
        let recorded = handle.recorded
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.url.host == "stub.local" && $0.url.port == 32400 })
        #expect(recorded.map(\.url.path) == ["/identity", "/library/sections"])
    }
}
