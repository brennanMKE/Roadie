import Foundation
import Testing
@testable import AudioCore

@Suite struct EQFFileTests {
    private static var preamble: [UInt8] { Array(EQFFile.header.utf8) + [0x1A] + Array("!--".utf8) }

    private static func presetBytes(name: String, values: [Int]) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        return nameBytes + [UInt8](repeating: 0, count: 257 - nameBytes.count) + values.map { UInt8(64 - $0) }
    }

    @Test func parsesAWinampPreset() throws {
        let rock = EQPreset.builtIn.first { $0.name == "Rock" }!
        let bytes = Self.preamble + Self.presetBytes(name: "Rock", values: [45, 40, 23, 19, 26, 39, 47, 50, 50, 50, 33])
        let presets = try EQFFile.parse(Data(bytes))
        #expect(presets.count == 1)
        #expect(presets[0].name == "Rock")
        #expect(presets[0] == rock)
    }

    @Test func parsesSeveralAndRejectsBadFiles() throws {
        let flat = Self.presetBytes(name: "One", values: Array(repeating: 33, count: 11))
        let loud = Self.presetBytes(name: "Two", values: Array(repeating: 64, count: 11))
        let two = try EQFFile.parse(Data(Self.preamble + flat + loud))
        #expect(two.map(\.name) == ["One", "Two"])
        #expect(two[1].preamp == 12 && two[1].gains == Array(repeating: 12, count: 10))

        let old = Array("Winamp EQ library file v1.0".utf8) + [0x1A] + Array("!--".utf8) + flat
        #expect(throws: EQFFile.ParseError.invalidHeader) { try EQFFile.parse(Data(old)) }
        #expect(throws: EQFFile.ParseError.invalidHeader) { try EQFFile.parse(Data()) }
        #expect(throws: EQFFile.ParseError.truncated) { try EQFFile.parse(Data((Self.preamble + flat).dropLast(3))) }
        #expect(try EQFFile.parse(Data(Self.preamble)) == [])
    }

    @Test func serializeRoundTrips() throws {
        let data = EQFFile.serialize(EQPreset.builtIn)
        #expect(data.count == 31 + 268 * 18)
        #expect(try EQFFile.parse(data) == EQPreset.builtIn)
        let bytes = [UInt8](data)
        #expect(bytes[31] == UInt8(ascii: "F"))
        #expect(Array(bytes[(31 + 257)..<(31 + 268)]) == [UInt8](repeating: 31, count: 11))
    }
}
