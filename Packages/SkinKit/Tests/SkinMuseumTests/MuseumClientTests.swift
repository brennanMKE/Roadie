import Foundation
import Testing

@testable import SkinMuseum

@Suite struct MuseumClientTests {
    private let userAgent = MuseumUserAgent.make(version: "9.9")

    private func client(_ transport: StubMuseumTransport, sleeps: SleepLog = SleepLog()) -> MuseumClient {
        MuseumClient(transport: transport, userAgent: userAgent, sleep: { sleeps.append($0) })
    }

    private func search(_ text: String = "zelda", includeNSFW: Bool = false, first: Int = 60) -> MuseumQuery {
        .search(text: text, offset: 0, first: first, includeNSFW: includeNSFW)
    }

    @Test func searchPostsNamedOperationWithVariables() async throws {
        let transport = StubMuseumTransport(.fixture("search-zelda"))
        let hostile = #"zelda") { bulkDownload { nodes { md5 } } } #"#
        _ = try await client(transport).page(search(hostile))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == MuseumClient.defaultEndpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Roadie/9.9 (+https://roadie.sstools.co/)")
        let body = try transport.body()
        #expect(body["operationName"] as? String == "MuseumSearch")
        let query = try #require(body["query"] as? String)
        #expect(query.contains("search_classic_skins"))
        #expect(!query.contains("zelda"))
        #expect(!query.contains("bulkDownload"))
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["query"] as? String == hostile)
        #expect(variables["first"] as? Int == 60)
        #expect(variables["offset"] as? Int == 0)
    }

    @Test func searchDecodesRecordedFixture() async throws {
        let page = try await client(StubMuseumTransport(.fixture("search-zelda"))).page(search())
        #expect(page.skins.map(\.md5) == [
            "1f8214678f97b888dfab7c251c943225", "205d326f05b5569b320d5abf6b6b4043", "db2df7b5351e20caac062fe48c9fd31c",
        ])
        let second = page.skins[1]
        #expect(second.filename == "ZeldaXtreme_[S130283].wsz")
        #expect(second.downloadURL.absoluteString == "https://r2.webampskins.org/skins/205d326f05b5569b320d5abf6b6b4043.wsz")
        #expect(second.screenshotURL.absoluteString == "https://r2.webampskins.org/screenshots/205d326f05b5569b320d5abf6b6b4043.png")
        #expect(second.museumURL.absoluteString == "https://skins.webamp.org/skin/205d326f05b5569b320d5abf6b6b4043")
        #expect(second.nsfw == false)
        #expect(page.total == nil)
    }

    @Test func browseDecodesCountAndNodes() async throws {
        let page = try await client(StubMuseumTransport(.fixture("skins-page1")))
            .page(.browse(offset: 0, first: 3, includeNSFW: true))
        #expect(page.total == 103332)
        #expect(page.skins.count == 3)
        #expect(page.hasMore)
    }

    @Test func hiddenNSFWDropsFlaggedRows() async throws {
        let page = try await client(StubMuseumTransport(.fixture("skins-page1")))
            .page(.browse(offset: 0, first: 3, includeNSFW: false))
        #expect(page.skins.map(\.md5) == ["8a2cfd657fa97b1a511b372f5249d63a", "aa0b1aae867bc4bac437b60c9d78c200"])
        // A page short only because of client filtering still has more.
        #expect(page.hasMore)
    }

    @Test func hiddenNSFWSendsServerFilter() async throws {
        let transport = StubMuseumTransport(.fixture("search-zelda"), .fixture("skins-page1"))
        let c = client(transport)
        _ = try await c.page(search(includeNSFW: false))
        _ = try await c.page(.browse(offset: 0, first: 60, includeNSFW: false))
        let searchVars = try #require(try transport.body(0)["variables"] as? [String: Any])
        #expect(searchVars["nsfw"] as? Bool == false)
        let browse = try transport.body(1)
        #expect(browse["operationName"] as? String == "MuseumBrowse")
        let browseVars = try #require(browse["variables"] as? [String: Any])
        #expect(browseVars["filter"] as? String == "APPROVED")
        #expect(browseVars["sort"] == nil)
    }

    @Test func shownNSFWKeepsFlaggedRows() async throws {
        let transport = StubMuseumTransport(.fixture("skins-page1"), .fixture("search-zelda"))
        let c = client(transport)
        let page = try await c.page(.browse(offset: 0, first: 60, includeNSFW: true))
        #expect(page.skins.contains { $0.nsfw == true })
        _ = try await c.page(search(includeNSFW: true))
        let browseVars = try #require(try transport.body(0)["variables"] as? [String: Any])
        #expect(browseVars["filter"] == nil)
        let searchVars = try #require(try transport.body(1)["variables"] as? [String: Any])
        #expect(searchVars["nsfw"] == nil)
    }

    @Test func nullNSFWRowIsKept() async throws {
        let page = try await client(StubMuseumTransport(.fixture("search-odd-rows"))).page(search())
        #expect(page.skins.contains { $0.md5 == "0123456789abcdef0123456789abcdef" && $0.nsfw == nil })
    }

    @Test func modernTypenameIsDropped() async throws {
        let page = try await client(StubMuseumTransport(.fixture("search-odd-rows"))).page(search(includeNSFW: true))
        #expect(!page.skins.contains { $0.md5 == "11111111111111111111111111111111" })
    }

    @Test func nonHTTPSURLRowIsDropped() async throws {
        let page = try await client(StubMuseumTransport(.fixture("search-odd-rows"))).page(search(includeNSFW: true))
        #expect(!page.skins.contains { $0.md5 == "22222222222222222222222222222222" })
        #expect(page.skins.count == 1)
    }

    @Test func graphQLErrorsBecomeMuseumError() async throws {
        let c = client(StubMuseumTransport(.fixture("graphql-error")))
        await #expect(throws: MuseumError.graphQL(#"Cannot query field "bogus" on type "Query"."#)) {
            try await c.page(search())
        }
    }

    @Test func notConnectedBecomesOffline() async throws {
        let c = client(StubMuseumTransport(.failure(.notConnectedToInternet)))
        await #expect(throws: MuseumError.offline) { try await c.page(search()) }
        let timedOut = client(StubMuseumTransport(.failure(.timedOut)))
        await #expect(throws: MuseumError.offline) { try await timedOut.page(search()) }
    }

    @Test func serverErrorStatusBecomesHTTPError() async throws {
        let transport = StubMuseumTransport(.status(500))
        await #expect(throws: MuseumError.http(500)) { try await client(transport).page(search()) }
        #expect(transport.requests.count == 1)
    }

    @Test func rateLimitRetriesOnceAfterRetryAfter() async throws {
        let sleeps = SleepLog()
        let transport = StubMuseumTransport(.status(429, headers: ["Retry-After": "120"]), .fixture("search-zelda"))
        let page = try await client(transport, sleeps: sleeps).page(search())
        #expect(page.skins.count == 3)
        #expect(transport.requests.count == 2)
        #expect(sleeps.values == [.seconds(10)])

        let again = SleepLog()
        let failing = StubMuseumTransport(.status(503, headers: ["Retry-After": "2"]))
        await #expect(throws: MuseumError.http(503)) { try await client(failing, sleeps: again).page(search()) }
        #expect(failing.requests.count == 2)
        #expect(again.values == [.seconds(2)])
    }

    @Test func shortPageHasNoMore() async throws {
        let empty = try await client(StubMuseumTransport(.fixture("search-empty"))).page(search())
        #expect(empty.skins.isEmpty)
        #expect(!empty.hasMore)
        let short = try await client(StubMuseumTransport(.fixture("search-zelda"))).page(search(first: 60))
        #expect(!short.hasMore)
        let full = try await client(StubMuseumTransport(.fixture("search-zelda"))).page(search(first: 3))
        #expect(full.hasMore)
        let lastBrowse = try await client(StubMuseumTransport(.fixture("skins-page1")))
            .page(.browse(offset: 103329, first: 3, includeNSFW: true))
        #expect(!lastBrowse.hasMore)
    }
}

@Suite struct SkinMuseumNetworkSeamTests {
    /// Only `URLSessionMuseumTransport` may touch URLSession; no test constructs it.
    @Test func onlyTransportFileReferencesURLSession() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/SkinMuseum")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let users = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("URLSession") }
            .map(\.lastPathComponent)
        #expect(users == ["MuseumTransport.swift"])
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    func append(_ value: Duration) { lock.withLock { recorded.append(value) } }
    var values: [Duration] { lock.withLock { recorded } }
}
