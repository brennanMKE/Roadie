import CryptoKit
import Foundation
import Testing

@testable import SkinLibrary

@Suite struct SkinIngesterTests {
    @Test func hashIsSHA256OfTheBytes() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let a = dir.appending("a.wsz"), b = dir.appending("b.wsz")
        try SyntheticSkins.write(to: a)
        try FileManager.default.copyItem(at: a, to: b)
        let ingester = SkinIngester()
        let expected = SHA256.hash(data: try Data(contentsOf: a)).map { String(format: "%02x", $0) }.joined()
        #expect(try ingester.hash(a) == expected)
        #expect(expected.count == 64)
        #expect(SkinContentHash.isValid(expected))
        #expect(try ingester.hash(b) == expected)
        var bytes = try Data(contentsOf: b)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: b)
        #expect(try ingester.hash(b) != expected)
    }

    @Test func contentHashValidation() {
        #expect(!SkinContentHash.isValid(String(repeating: "A", count: 64)))
        #expect(!SkinContentHash.isValid(String(repeating: "a", count: 63)))
        #expect(!SkinContentHash.isValid("../" + String(repeating: "a", count: 61)))
    }

    @Test func inspectReportsOkPartialAndFailed() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let ok = dir.appending("ok.wsz"), partial = dir.appending("partial.wsz")
        let modern = dir.appending("modern.wsz"), garbage = dir.appending("garbage.wsz")
        try SyntheticSkins.write(to: ok)
        try SyntheticSkins.write(to: partial, omitting: ["CBUTTONS"])
        try SyntheticSkins.modern(to: modern)
        try SyntheticSkins.garbage(to: garbage)
        let ingester = SkinIngester()
        let okResult = ingester.inspect(ok)
        #expect(okResult.status == .ok, "warnings: \(okResult.warnings)")
        #expect(okResult.warnings.isEmpty)
        let partialResult = ingester.inspect(partial)
        #expect(partialResult.status == .partial)
        #expect(partialResult.warnings.contains("Missing cbuttons.bmp"))
        let modernResult = ingester.inspect(modern)
        #expect(modernResult.status == .failed)
        #expect(modernResult.warnings == ["Modern (Winamp 3/5) skin; not supported"])
        let garbageResult = ingester.inspect(garbage)
        #expect(garbageResult.status == .failed)
        #expect(garbageResult.warnings.first?.hasPrefix("Unreadable archive") == true)
    }

    @Test func inspectReadsTheReadmeEvenWhenParsingFails() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let modern = dir.appending("modern.wsz")
        try SyntheticSkins.modern(to: modern, readme: "Modern skin by Someone")
        let result = SkinIngester().inspect(modern)
        #expect(result.status == .failed)
        #expect(result.readme == "Modern skin by Someone")
    }

    @Test func hashThrowsForAMissingFile() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        #expect(throws: (any Error).self) { try SkinIngester().hash(dir.appending("nope.wsz")) }
    }
}
