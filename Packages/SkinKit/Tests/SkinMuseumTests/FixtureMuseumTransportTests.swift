import CryptoKit
import Foundation
import SkinMuseumStub
import Testing

@testable import SkinMuseum

/// #0194: the app's test configuration answers the Museum from fixtures and a local folder, never the network.
@Suite struct FixtureMuseumTransportTests {
    @Test func fixtureTransportAnswersPagesAndLocalDownloads() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "museum-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("not really a skin".utf8)
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: folder.appending(path: "Local.wsz"))

        let transport = FixtureMuseumTransport(skinsFolder: folder)
        let client = MuseumClient(transport: transport, userAgent: "test")
        let search = try await client.page(.search(text: "zelda", offset: 0, first: 60, includeNSFW: false))
        #expect(!search.skins.isEmpty)
        let browse = try await client.page(.browse(offset: 0, first: 60, includeNSFW: false))
        #expect(!browse.skins.isEmpty)
        #expect(search.skins.map(\.md5) != browse.skins.map(\.md5))

        let hit = try await transport.send(URLRequest(url: URL(string: "https://r2.webampskins.org/skins/\(md5).wsz")!))
        #expect(hit.1.statusCode == 200)
        #expect(hit.0 == bytes)
        let miss = try await transport.send(
            URLRequest(url: URL(string: "https://r2.webampskins.org/skins/\(String(repeating: "0", count: 32)).wsz")!))
        #expect(miss.1.statusCode == 404)
    }
}
