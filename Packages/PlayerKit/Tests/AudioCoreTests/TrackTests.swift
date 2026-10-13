import AVFoundation
import Foundation
import Testing
@testable import AudioCore

@Suite struct TrackTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func fileTrackReportsFormat() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "silence.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        do {
            let out = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            try out.write(from: buffer)
        }
        let track = try Track.file(at: url)
        #expect(track.title == "silence")
        #expect(track.sampleRate == 48_000)
        #expect(track.channels == 2)
        #expect(abs(track.duration - 1.0) < 0.001)
        #expect(track.source == .file(url))
    }

    @Test func nonAudioFileThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Track.file(at: url) }
    }
}
