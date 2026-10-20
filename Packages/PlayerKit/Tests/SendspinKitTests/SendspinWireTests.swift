import Foundation
import Testing
@testable import SendspinKit

struct SendspinWireTests {
    @Test func audioChunkParsesTimestampAndPayload() throws {
        var data = Data([4])
        withUnsafeBytes(of: Int64(1_234_567_890).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [1, 2, 3, 4])
        let chunk = try #require(try SendspinWire.parseAudioChunk(data, wire: .legacy))
        #expect(chunk.serverMicros == 1_234_567_890)
        #expect(chunk.payload == Data([1, 2, 3, 4]))
        #expect(chunk.payload.startIndex == 0)
    }

    @Test func nonAudioBinaryIsIgnored() throws {
        #expect(try SendspinWire.parseAudioChunk(Data([8, 0, 0, 0, 0, 0, 0, 0, 0, 1]), wire: .legacy) == nil)
    }

    @Test func shortAudioChunkThrows() {
        #expect(throws: SendspinError.malformed(type: "audio")) {
            try SendspinWire.parseAudioChunk(Data([4, 0, 0, 0, 1]), wire: .legacy)
        }
    }
}
