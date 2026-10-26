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

    /// #0208: `featuredSkin` rewrites the browse page's first row to that file's md5 and name; without it, as recorded.
    @Test func featuredSkinLeadsTheBrowsePage() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "museum-featured-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("featured".utf8)
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: folder.appending(path: "Aaa.wsz"))
        try Data("other".utf8).write(to: folder.appending(path: "Pika.wsz"))

        let featured = MuseumClient(transport: FixtureMuseumTransport(skinsFolder: folder, featuredSkin: "Pika"), userAgent: "t")
        let page = try await featured.page(.browse(offset: 0, first: 60, includeNSFW: false))
        let pikaMD5 = Insecure.MD5.hash(data: Data("other".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(page.skins.first?.md5 == pikaMD5)
        #expect(!page.skins.contains { $0.md5 == md5 })

        let plain = MuseumClient(transport: FixtureMuseumTransport(skinsFolder: folder), userAgent: "t")
        let recorded = try await plain.page(.browse(offset: 0, first: 60, includeNSFW: false))
        #expect(recorded.skins.first?.md5 != pikaMD5)
    }
}
