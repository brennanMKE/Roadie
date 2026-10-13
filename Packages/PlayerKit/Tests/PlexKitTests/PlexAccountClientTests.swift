import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexAccountClientTests {
    private func make() -> (StubURLProtocol.Handle, PlexAccountClient) {
        let handle = StubURLProtocol.handle()
        return (handle, PlexTv.account(handle))
    }

    @Test func createPinPostsWithoutAToken() async throws {
        let (handle, account) = make()
        handle.register([try PlexTv.createRoute()])
        let pin = try await account.createPin()
        let request = try #require(handle.recorded.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v2/pins")
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "strong", value: "true")])
        #expect(PlexTv.header(request, "Accept") == "application/json")
        #expect(PlexTv.header(request, "X-Plex-Product") == "SkinAmp")
        #expect(PlexTv.header(request, "X-Plex-Client-Identifier") == PlexTv.identifier)
        #expect(PlexTv.header(request, "X-Plex-Token") == nil)
        #expect(pin.id == 123456789)
        #expect(pin.code.count == 24)
        #expect(pin.authToken == nil)
        #expect(!pin.isClaimed)
    }

    @Test func pollSendsTheIdAndCodeWithoutAToken() async throws {
        let (handle, account) = make()
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute()])
        let created = try await account.createPin()
        _ = try await account.pin(created)
        let request = try #require(handle.recorded.last)
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/v2/pins/123456789")
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "code", value: created.code)])
        #expect(PlexTv.header(request, "X-Plex-Token") == nil)
    }

    @Test func claimedPinCarriesARedactedToken() async throws {
        let fake = try PlexTv.fakeToken
        let (handle, account) = make()
        handle.register([try PlexTv.createRoute(), try PlexTv.pollRoute(.pinClaimed)])
        let created = try await account.createPin()
        let claimed = try await account.pin(created)
        #expect(claimed.authToken == PlexToken(fake))
        #expect(claimed.isClaimed)
        var dumped = ""
        dump(claimed, to: &dumped)
        for text in [String(describing: claimed), String(reflecting: claimed), dumped] {
            #expect(!text.contains(fake))
        }
        #expect(String(describing: claimed) == "PlexPin(claimed: true)")
        let type: Any.Type = PlexPin.self
        #expect(!(type is any Encodable.Type))
    }

    @Test func authURLCarriesOnlyClientIDCodeAndProduct() async throws {
        let fake = try PlexTv.fakeToken
        let (_, account) = make()
        let claimed = try JSONDecoder().decode(PlexPin.self, from: PlexFixture.pinClaimed.data)
        let url = account.authURL(for: claimed)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "app.plex.tv")
        #expect(components.path == "/auth")
        #expect(components.query == nil)
        let fragment = try #require(components.fragment)
        #expect(fragment.hasPrefix("?"))
        var pairs: [String: String] = [:]
        for part in fragment.dropFirst().split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            pairs[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        #expect(pairs == [
            "clientID": PlexTv.identifier,
            "code": claimed.code,
            "context[device][product]": "SkinAmp",
        ])
        let text = url.absoluteString
        for forbidden in [fake, "token", "authToken", "X-Plex-Token"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test func resourcesSendTheTokenInTheHeaderAndKeepServersOnly() async throws {
        let (handle, account) = make()
        handle.register([try PlexTv.resourcesRoute()])
        let servers = try await account.resources(token: PlexToken("tok-header-check"))
        let request = try #require(handle.recorded.first)
        #expect(request.url.path == "/api/v2/resources")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(.init(name: "includeHttps", value: "1")))
        #expect(items.contains(.init(name: "includeRelay", value: "1")))
        #expect(!items.contains { $0.name.lowercased() == "x-plex-token" })
        #expect(PlexTv.header(request, "X-Plex-Token") == "tok-header-check")
        #expect(servers.map(\.name) == ["fixture-server", "fixture-shared"])
    }

    @Test func accessTokenIsNeverDecoded() throws {
        let fixture = String(decoding: try PlexFixture.resources.data, as: UTF8.self)
        #expect(!fixture.contains("accessToken"))
        let json = """
        {"name": "s", "clientIdentifier": "abc", "provides": "server", "owned": true, "accessToken": "tok-SHOULD-NOT-APPEAR"}
        """
        let resource = try JSONDecoder().decode(PlexResource.self, from: Data(json.utf8))
        #expect(!Mirror(reflecting: resource).children.contains { $0.label == "accessToken" })
        #expect(!String(reflecting: resource).contains("tok-SHOULD-NOT-APPEAR"))
        var dumped = ""
        dump(resource, to: &dumped)
        #expect(!dumped.contains("tok-SHOULD-NOT-APPEAR"))
    }

    @Test func plexTvErrorsMapLikeTheServerClient() async throws {
        let fake = try PlexTv.fakeToken
        let (handle, account) = make()
        handle.register([try PlexTv.createRoute(status: 500)])
        await #expect(throws: PlexError.httpStatus(500)) { _ = try await account.createPin() }

        handle.register([try PlexTv.pollRoute(status: 404)])
        let pin = try JSONDecoder().decode(PlexPin.self, from: PlexFixture.pinCreated.data)
        await #expect(throws: PlexError.notFound) { _ = try await account.pin(pin) }

        handle.register([try PlexTv.resourcesRoute(status: 401)])
        await #expect(throws: PlexError.unauthorized) { _ = try await account.resources(token: PlexToken(fake)) }

        for error in [PlexError.httpStatus(500), .notFound, .unauthorized] {
            #expect(!String(describing: error).contains(fake))
            #expect(!(error.errorDescription ?? "").contains(fake))
        }
    }
}
