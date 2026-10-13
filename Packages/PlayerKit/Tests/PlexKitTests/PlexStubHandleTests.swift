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
}
