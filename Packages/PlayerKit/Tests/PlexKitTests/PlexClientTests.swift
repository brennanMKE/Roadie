import Foundation
import Testing
import PlexKit
import PlexKitStub

@Suite(.serialized)
struct PlexClientTests {
    static let secret = "tok-UNIT-TEST-SECRET-0123"
    static let identifier = "11111111-2222-3333-4444-555555555555"

    private func client(token: PlexToken? = PlexToken(PlexClientTests.secret), base: String = "http://stub.local:32400") -> PlexClient {
        StubURLProtocol.reset()
        return PlexClient(baseURL: URL(string: base)!, token: token, clientIdentifier: Self.identifier,
                          session: StubURLProtocol.session())
    }

    private func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
        request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    @Test func everyRequestSendsPlexHeaders() async throws {
        let client = client()
        StubURLProtocol.register([try .json(.sections, path: "/library/sections")])
        _ = try await client.librarySections()
        let request = try #require(StubURLProtocol.recorded.first)
        #expect(header(request, "Accept") == "application/json")
        #expect(header(request, "X-Plex-Token") == Self.secret)
        #expect(header(request, "X-Plex-Client-Identifier") == Self.identifier)
        #expect(header(request, "X-Plex-Product") == "SkinAmp")
        #expect(header(request, "X-Plex-Version") != nil)
        #expect(header(request, "X-Plex-Platform") == "macOS")
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems == nil)
        #expect(!request.url.absoluteString.contains(Self.secret))
    }

    @Test func identityWithoutTokenSendsNoTokenHeader() async throws {
        let client = client(token: nil)
        StubURLProtocol.register([try .json(.identity, path: "/identity")])
        let identity = try await client.identity()
        #expect(!identity.machineIdentifier.isEmpty)
        let request = try #require(StubURLProtocol.recorded.first)
        #expect(header(request, "X-Plex-Token") == nil)
    }

    @Test func listCallsSendBothPagingHeaders() async throws {
        let client = client()
        StubURLProtocol.register([
            try .json(.artistsPage, path: "/library/sections/9/all"),
            try .json(.identity, path: "/identity"),
            try .json(.sections, path: "/library/sections"),
        ])
        _ = try await client.artists(in: "9", page: .init(start: 20, size: 50))
        _ = try await client.identity()
        _ = try await client.librarySections()
        let recorded = StubURLProtocol.recorded
        #expect(header(recorded[0], "X-Plex-Container-Start") == "20")
        #expect(header(recorded[0], "X-Plex-Container-Size") == "50")
        for request in recorded.dropFirst() {
            #expect(header(request, "X-Plex-Container-Start") == nil)
            #expect(header(request, "X-Plex-Container-Size") == nil)
        }
    }

    @Test func sectionIdComesFromTheCaller() async throws {
        let client = client()
        StubURLProtocol.register([
            try .json(.artistsPage, path: "/library/sections/9/all", query: ["type": "8"]),
            try .json(.albumsPage, path: "/library/sections/9/all", query: ["type": "9"]),
            try .json(.tracksPage, path: "/library/sections/9/all", query: ["type": "10"]),
        ])
        _ = try await client.artists(in: "9")
        _ = try await client.albums(in: "9")
        _ = try await client.tracks(in: "9")
        let recorded = StubURLProtocol.recorded
        #expect(recorded.map(\.url.path) == Array(repeating: "/library/sections/9/all", count: 3))
        let types = recorded.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "type" }?.value }
        #expect(types == ["8", "9", "10"])
    }

    @Test func childrenUseMetadataPath() async throws {
        let client = client()
        StubURLProtocol.register([
            try .json(.artistChildren, path: "/library/metadata/3030/children"),
            try .json(.albumChildren, path: "/library/metadata/3040/children"),
        ])
        let albums = try await client.albums(of: "3030")
        let tracks = try await client.tracks(of: "3040")
        #expect(!albums.items.isEmpty)
        #expect(!tracks.items.isEmpty)
        #expect(StubURLProtocol.recorded.map(\.url.path) == ["/library/metadata/3030/children", "/library/metadata/3040/children"])
    }

    @Test func searchEncodesTitle() async throws {
        let client = client()
        StubURLProtocol.register([try .json(.tracksSearch, path: "/library/sections/9/all")])
        _ = try await client.searchTracks(in: "9", title: "cowboys & aliens")
        let url = try #require(StubURLProtocol.recorded.first?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "type" }?.value == "10")
        #expect(items.first { $0.name == "title" }?.value == "cowboys & aliens")
        #expect(url.absoluteString.contains("title=cowboys%20%26%20aliens"))
    }

    @Test func baseURLWithTrailingSlashJoinsOnce() async throws {
        for base in ["http://stub.local:32400", "http://stub.local:32400/"] {
            let client = client(base: base)
            StubURLProtocol.register([try .json(.sections, path: "/library/sections")])
            _ = try await client.librarySections()
            #expect(StubURLProtocol.recorded.first?.url.path == "/library/sections")
        }
    }

    @Test func pageFieldsComeFromTheContainer() async throws {
        let client = client()
        StubURLProtocol.register([try .json(.tracksPage, path: "/library/sections/9/all")])
        let page = try await client.tracks(in: "9")
        let json = try JSONSerialization.jsonObject(with: PlexFixture.tracksPage.data) as? [String: Any]
        let total = (json?["MediaContainer"] as? [String: Any])?["totalSize"] as? Int
        #expect(page.size == 3)
        #expect(page.offset == 0)
        #expect(page.totalSize == total)
        #expect(page.hasMore)
        #expect(page.next?.start == 3)
    }

    @Test func allItemsWalksPages() async throws {
        let client = client()
        var json = try #require(JSONSerialization.jsonObject(with: PlexFixture.tracksPage.data) as? [String: Any])
        var container = try #require(json["MediaContainer"] as? [String: Any])
        container["totalSize"] = 4
        json["MediaContainer"] = container
        let first = try JSONSerialization.data(withJSONObject: json)
        StubURLProtocol.register([
            .init(path: "/library/sections/9/all", containerStart: 0, body: first),
            .init(path: "/library/sections/9/all", containerStart: 3, body: try PlexFixture.tracksLastPage.data),
        ])
        let all = try await client.allItems(pageSize: 3) { page in
            try await client.tracks(in: "9", page: page)
        }
        #expect(all.count == 4)
        #expect(StubURLProtocol.recorded.count == 2)
    }

    @Test func unauthorizedMapsToPlexError() async throws {
        let client = client()
        StubURLProtocol.register([.init(path: "/library/sections", status: 401, headers: ["Content-Type": "text/html"], body: Data("<html/>".utf8))])
        await #expect(throws: PlexError.unauthorized) { _ = try await client.librarySections() }
    }

    @Test func otherStatusesMap() async throws {
        let client = client()
        StubURLProtocol.register([.init(path: "/library/sections", status: 404)])
        await #expect(throws: PlexError.notFound) { _ = try await client.librarySections() }
        StubURLProtocol.register([.init(path: "/library/sections", status: 500)])
        await #expect(throws: PlexError.httpStatus(500)) { _ = try await client.librarySections() }
    }

    @Test func transportErrorMapsToCode() async throws {
        let client = client()
        StubURLProtocol.register([.init(path: "/identity", error: URLError(.cannotConnectToHost))])
        await #expect(throws: PlexError.transport(.cannotConnectToHost)) { _ = try await client.identity() }
    }

    @Test func xmlResponseIsNotJSON() async throws {
        let client = client()
        StubURLProtocol.register([.init(path: "/library/sections", headers: ["Content-Type": "text/xml"], body: Data("<MediaContainer/>".utf8))])
        await #expect(throws: PlexError.notJSON(contentType: "text/xml")) { _ = try await client.librarySections() }
    }

    @Test func malformedJSONIsDecodingError() async throws {
        let client = client()
        let body = #"{"MediaContainer":{"Metadata":[{"ratingKey":"1","key":"/k","title":1}]}}"#
        StubURLProtocol.register([.init(path: "/library/sections/9/all", body: Data(body.utf8))])
        do {
            _ = try await client.artists(in: "9")
            Issue.record("expected a decoding error")
        } catch let PlexError.decoding(path, detail) {
            #expect(path.contains("title"))
            #expect(detail.contains("title"))
            #expect(!detail.contains("ratingKey"))
        }
    }

    @Test func tokenNeverAppearsInErrors() async throws {
        let client = client()
        var errors: [any Error] = []
        let cases: [StubURLProtocol.Route] = [
            .init(path: "/identity", status: 401),
            .init(path: "/identity", status: 404),
            .init(path: "/identity", status: 500),
            .init(path: "/identity", error: URLError(.timedOut)),
            .init(path: "/identity", headers: ["Content-Type": "text/xml"], body: Data("<x/>".utf8)),
            .init(path: "/identity", body: Data(#"{"MediaContainer":{"machineIdentifier":1}}"#.utf8)),
        ]
        for route in cases {
            StubURLProtocol.register([route])
            do { _ = try await client.identity() } catch { errors.append(error) }
        }
        #expect(errors.count == cases.count)
        for error in errors {
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                #expect(!text.contains(Self.secret))
            }
        }
        #expect(!String(reflecting: client).contains(Self.secret))
        #expect(!String(describing: client).contains(Self.secret))
    }
}
