import Foundation
import Testing
import PlexKit

struct PlexAddressTests {
    private func normalized(_ text: String) throws -> String {
        try PlexAddress.normalize(text).absoluteString
    }

    @Test(arguments: [
        ("joe", "http://joe:32400"),
        ("joe:32400", "http://joe:32400"),
        ("http://joe:32400", "http://joe:32400"),
        ("192.168.1.10", "http://192.168.1.10:32400"),
    ])
    func documentedFormsNormalize(input: String, expected: String) throws {
        #expect(try normalized(input) == expected)
    }

    @Test(arguments: [
        ("https://joe:32400", "https://joe:32400"),
        ("https://1-2-3-4.abcdef.plex.direct:32400", "https://1-2-3-4.abcdef.plex.direct:32400"),
    ])
    func httpsIsKept(input: String, expected: String) throws {
        #expect(try normalized(input) == expected)
    }

    @Test(arguments: [("joe:3000", "http://joe:3000"), ("http://joe:8080", "http://joe:8080")])
    func customPortsAreKept(input: String, expected: String) throws {
        #expect(try normalized(input) == expected)
    }

    @Test(arguments: ["  joe  ", "joe\n", "joe/", "http://joe:32400/"])
    func whitespaceAndTrailingSlashAreRemoved(input: String) throws {
        #expect(try normalized(input) == "http://joe:32400")
    }

    @Test func schemeAndHostAreLowercased() throws {
        #expect(try normalized("HTTP://Joe:32400") == "http://joe:32400")
    }

    @Test(arguments: [
        ("brennan-mac-mini-m1.local", "http://brennan-mac-mini-m1.local:32400"),
        ("joe.tailnet.ts.net", "http://joe.tailnet.ts.net:32400"),
    ])
    func localAndTailscaleNamesPassThrough(input: String, expected: String) throws {
        #expect(try normalized(input) == expected)
    }

    @Test func nonRootPathIsKept() throws {
        let url = try PlexAddress.normalize("http://joe:32400/plex/")
        #expect(url.absoluteString == "http://joe:32400/plex")
        let client = PlexClient(baseURL: url, token: nil, clientIdentifier: "x")
        #expect(client.request(path: "/identity").url?.path == "/plex/identity")
    }

    @Test(arguments: [
        ("http://joe:32400/web/index.html", "http://joe:32400"),
        ("http://joe:32400/web/", "http://joe:32400"),
        ("http://joe:32400/web", "http://joe:32400"),
        ("joe:32400/web/index.html#!/media/x", "http://joe:32400"),
        ("http://joe:32400/plex/web/index.html", "http://joe:32400/plex"),
        ("http://joe:32400/webhooks", "http://joe:32400/webhooks"),
    ])
    func plexWebPathIsStripped(input: String, expected: String) throws {
        #expect(try normalized(input) == expected)
    }

    @Test(arguments: ["joe?x=1#f", "http://joe:32400/?X-Plex-Token=abc"])
    func queryAndFragmentAreDropped(input: String) throws {
        let result = try normalized(input)
        #expect(result == "http://joe:32400")
        #expect(!result.contains("abc"))
    }

    @Test(arguments: ["", "   ", "ftp://joe", "http://", "joe:notaport", "joe:0", "joe:99999",
                      "http://user:pw@joe", "ht tp://joe", "joe:32400:1"])
    func invalidAddressesThrow(input: String) {
        #expect(throws: PlexError.invalidBaseURL) { _ = try PlexAddress.normalize(input) }
    }

    @Test(arguments: ["joe", "joe:3000", "https://joe", "HTTP://Joe:32400/plex/", "192.168.1.10",
                      "joe.tailnet.ts.net", "joe?x=1", "http://joe:32400/web/index.html",
                      "http://joe:32400/plex/web/index.html"])
    func normalizeIsIdempotent(input: String) throws {
        let once = try PlexAddress.normalize(input)
        #expect(try PlexAddress.normalize(once.absoluteString) == once)
    }

    @Test func clientInitFromAddress() throws {
        let client = try PlexClient(address: "joe", token: nil, clientIdentifier: "x")
        #expect(client.baseURL.absoluteString == "http://joe:32400")
        #expect(throws: PlexError.invalidBaseURL) {
            _ = try PlexClient(address: "ftp://joe", token: nil, clientIdentifier: "x")
        }
    }
}
