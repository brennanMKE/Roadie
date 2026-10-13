import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexServerResolverTests {
    static let hash = "0123456789abcdef0123456789abcdef"
    static let localHost = "10-0-0-5.\(hash).plex.direct"
    static let remoteHost = "203-0-113-5.\(hash).plex.direct"

    private func make() -> (StubURLProtocol.Handle, PlexServerResolver, PlexResource) {
        let handle = StubURLProtocol.handle()
        let resolver = PlexServerResolver(clientIdentifier: PlexTv.identifier, session: handle.session)
        let resources = try! JSONDecoder().decode([PlexResource].self, from: PlexFixture.resources.data)
        return (handle, resolver, resources.first { $0.name == "fixture-server" }!)
    }

    private func identity(_ machine: String = PlexTv.machine) throws -> Data {
        let text = String(decoding: try PlexFixture.identity.data, as: UTF8.self)
            .replacingOccurrences(of: PlexTv.machine, with: machine)
        return Data(text.utf8)
    }

    private func failing(_ host: String?) -> StubURLProtocol.Route {
        .init(path: "/identity", host: host, error: URLError(.cannotConnectToHost))
    }

    @Test func bestRankedReachableConnectionWins() async throws {
        let (handle, resolver, resource) = make()
        handle.register([
            failing(Self.localHost), failing("fd00--5.\(Self.hash).plex.direct"), failing("10.0.0.5"),
            .init(path: "/identity", host: Self.remoteHost, body: try identity()),
        ])
        let found = try #require(await resolver.reachableConnection(of: resource))
        #expect(found.url?.host == Self.remoteHost)
        #expect(found.uri.hasSuffix(":32400"))
        #expect(!found.local)
        #expect(handle.recorded.count == resource.connections.count)
        #expect(handle.recorded.allSatisfy { PlexTv.header($0, "X-Plex-Token") == nil })
    }

    @Test func wrongServerIsSkipped() async throws {
        let (handle, resolver, resource) = make()
        handle.register([
            .init(path: "/identity", host: Self.localHost, body: try identity("ffffffffffffffffffffffffffffffffffffffff")),
            .init(path: "/identity", host: Self.remoteHost, body: try identity()),
        ])
        let found = try #require(await resolver.reachableConnection(of: resource))
        #expect(found.url?.host == Self.remoteHost)
    }

    @Test func nothingReachableIsNil() async {
        let (handle, resolver, resource) = make()
        handle.register([failing(nil)])
        #expect(await resolver.reachableConnection(of: resource) == nil)
    }

    @Test func localWinsWhenItAnswers() async throws {
        let (handle, resolver, resource) = make()
        handle.register([.init(path: "/identity", body: try identity())])
        let found = try #require(await resolver.reachableConnection(of: resource))
        #expect(found.url?.host == Self.localHost)
        #expect(found.local)
        #expect(!found.ipv6)
        #expect(found.isHTTPS)
    }
}
