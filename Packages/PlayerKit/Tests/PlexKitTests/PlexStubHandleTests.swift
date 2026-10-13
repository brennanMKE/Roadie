import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexStubHandleTests {
    @Test func handlesDoNotShareRoutesOrRecordings() async throws {
        let a = StubURLProtocol.handle()
        let b = StubURLProtocol.handle()
        a.register([try .json(.identity, path: "/identity")])
        b.register([])
        let base = URL(string: "http://stub.local:32400")!

        let clientA = PlexClient(baseURL: base, token: nil, clientIdentifier: "x", session: a.session)
        _ = try await clientA.identity()
        let clientB = PlexClient(baseURL: base, token: nil, clientIdentifier: "x", session: b.session)
        await #expect(throws: PlexError.notFound) { _ = try await clientB.identity() }

        #expect(a.recorded.count == 1)
        #expect(b.recorded.count == 1)
        #expect(a.recorded.allSatisfy { $0.headers.keys.allSatisfy { $0.lowercased() != StubURLProtocol.sessionHeader.lowercased() } })
    }

    @Test func routesCanMatchOnHost() async throws {
        let handle = StubURLProtocol.handle()
        let identity = try PlexFixture.identity.data
        let other = Data(String(decoding: identity, as: UTF8.self).replacingOccurrences(of: "0123456789abcdef0123456789abcdef01234567", with: "other-machine").utf8)
        handle.register([
            .init(path: "/identity", host: "a.local", body: identity),
            .init(path: "/identity", host: "b.local", body: other),
        ])
        func machine(_ host: String) async throws -> String {
            let client = PlexClient(baseURL: URL(string: "http://\(host):32400")!, token: nil, clientIdentifier: "x", session: handle.session)
            return try await client.identity().machineIdentifier
        }
        #expect(try await machine("a.local") == "0123456789abcdef0123456789abcdef01234567")
        #expect(try await machine("b.local") == "other-machine")
        await #expect(throws: PlexError.notFound) { _ = try await machine("c.local") }

        handle.register([.init(path: "/identity", host: nil, body: identity)])
        #expect(try await machine("c.local") == "0123456789abcdef0123456789abcdef01234567")
    }

    @Test func stoppedLoadsAreRecordedAsCancelled() async throws {
        let handle = StubURLProtocol.handle()
        let identity = try PlexFixture.identity.data
        handle.register([.init(path: "/identity", body: identity, delay: 60)])
        let client = PlexClient(baseURL: URL(string: "http://stub.local:32400")!, token: nil, clientIdentifier: "x", session: handle.session)
        let task = Task { try await client.identity() }
        #expect(await PlexTv.wait { handle.recorded.count == 1 })
        task.cancel()
        await #expect(throws: PlexError.transport(.cancelled)) { _ = try await task.value }
        #expect(await PlexTv.wait { handle.cancelled.count == 1 })
        #expect(handle.cancelled.first?.url.path == "/identity")

        // A load that completes normally also gets stopLoading; it is not a cancel.
        handle.register([.init(path: "/identity", body: identity)])
        _ = try await client.identity()
        #expect(handle.recorded.count == 2)
        #expect(handle.cancelled.count == 1)
    }
}
