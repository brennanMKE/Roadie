import CryptoKit
import Foundation
import Testing

@testable import SkinLibrary

@Suite struct SkinContentHashTests {
    @Test func hexMatchesCryptoKitAndIsStable() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let a = dir.appending("a.wsz"), b = dir.appending("b.wsz")
        try SyntheticSkins.write(to: a)
        try FileManager.default.copyItem(at: a, to: b)
        let expected = SHA256.hash(data: try Data(contentsOf: a)).map { String(format: "%02x", $0) }.joined()
        let hash = try SkinContentHash.hex(of: a)
        #expect(hash == expected)
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(try SkinContentHash.hex(of: b) == hash)
        var bytes = try Data(contentsOf: b)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: b)
        #expect(try SkinContentHash.hex(of: b) != hash)
        #expect(throws: (any Error).self) { try SkinContentHash.hex(of: dir.appending("missing.wsz")) }
        #expect(SkinContentHash.isValid(hash))
        #expect(!SkinContentHash.isValid(hash.uppercased()))
        #expect(!SkinContentHash.isValid(String(hash.dropLast())))
        #expect(!SkinContentHash.isValid("../" + String(repeating: "a", count: 61)))
    }
}
