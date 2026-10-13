import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexResourceTests {
    private func fixture() throws -> [PlexResource] {
        try JSONDecoder().decode([PlexResource].self, from: PlexFixture.resources.data)
    }

    @Test func connectionsRankLocalHTTPSFirst() throws {
        let server = try #require(try fixture().first { $0.name == "fixture-server" })
        let ranked = server.rankedConnections
        #expect(ranked.count == 5)
        #expect(ranked.map(\.isHTTPS) == [true, true, true, true, false])
        #expect(ranked.map(\.local) == [true, true, false, false, true])
        #expect(ranked.map(\.relay) == [false, false, false, true, false])
        #expect(ranked.map(\.ipv6) == [false, true, false, false, false])
        #expect(ranked.map(\.tier) == [.localHTTPS, .localHTTPS, .remoteHTTPS, .relay, .http])
        #expect(PlexResourceConnection.Tier.localHTTPS < .remoteHTTPS)
        #expect(PlexResourceConnection.Tier.relay < .http)
        #expect([PlexResourceConnection.Tier.localHTTPS, .remoteHTTPS, .relay, .http].map(\.name)
            == ["local https", "remote https", "relay", "http"])
        let preferred = try #require(server.preferredConnection)
        #expect(preferred.isPlexDirect)
        #expect(preferred.isHTTPS)
        #expect(preferred.local)
        #expect(preferred.url?.host == "10-0-0-5.0123456789abcdef0123456789abcdef.plex.direct")
    }

    @Test func serversWithoutConnectionsHaveNoPreferred() throws {
        let shared = try #require(try fixture().first { $0.name == "fixture-shared" })
        let preferred = try #require(shared.preferredConnection)
        #expect(!preferred.local)
        #expect(preferred.isHTTPS)

        let bare = try JSONDecoder().decode(PlexResource.self, from: Data(#"{"name":"x","clientIdentifier":"y","provides":"server","owned":true}"#.utf8))
        #expect(bare.connections.isEmpty)
        #expect(bare.preferredConnection == nil)
    }

    @Test(arguments: [("server", true), ("server,client", true), ("client", false), ("", false)])
    func isServerReadsProvides(provides: String, expected: Bool) {
        let resource = PlexResource(name: "n", clientIdentifier: "c", provides: provides)
        #expect(resource.isServer == expected)
    }
}
