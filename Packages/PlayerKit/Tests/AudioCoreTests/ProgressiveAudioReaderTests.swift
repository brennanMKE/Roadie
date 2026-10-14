import AVFoundation
import Foundation
import Testing
@testable import AudioCore

/// The reader without an engine: CoreAudio opens and decodes a file whose bytes the test releases.
@Suite struct ProgressiveAudioReaderTests {
    static let stereo = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    /// Decodes everything from the current position; returns the left channel.
    static func readAll(_ reader: ProgressiveAudioReader, chunk: AVAudioFrameCount = 1024) throws -> [Float] {
        var out: [Float] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: chunk)!
        while true {
            let n = try reader.read(into: buffer)
            if n == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(n)))
        }
        return out
    }

    static func fileSamples(_ url: URL) throws -> (frames: Int64, left: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file.length, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }

    @Test func openWaitsForTheHeader() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        let source = TrickleByteSource(data: wav.data, available: 0)
        let opened = Flag()
        let task = Task {
            let reader = try await ProgressiveAudioReader.open(source)
            opened.set()
            return reader
        }
        // The reader is blocked on the header, not failing: it has asked for bytes.
        #expect(await waitFor { source.waitCount > 0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!opened.isSet)
        source.advance(to: 12288)
        let reader = try await task.value
        #expect(reader.lengthFrames == 22050)
        #expect(reader.fileSampleRate == 44100)
        #expect(reader.fileChannels == 2)
        reader.close()
        #expect(await waitFor { source.isClosed })
    }

    @Test func readsOnlyAsFarAsTheBytesHaveArrived() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        let source = TrickleByteSource(data: wav.data, available: 12288 + (Int64(wav.data.count) - 12288) / 2)
        let reader = try await ProgressiveAudioReader.open(source)
        try await reader.setClientFormat(Self.stereo.streamDescription.pointee)
        let frames = Counter()
        let done = Flag()
        let thread = Thread {
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 1024)!
            while let n = try? reader.read(into: buffer), n > 0 { frames.add(Int(n)) }
            done.set()
        }
        thread.start()
        #expect(await waitFor { source.waitCount > 0 })
        #expect(!done.isSet)
        let half = frames.value
        #expect(half >= 4096 && half <= 11025 + 1024, "decoded \(half) frames from half the bytes")
        source.advance(to: source.finalSize)
        #expect(await waitFor { done.isSet })
        #expect(frames.value == 22050)
        reader.close()
    }

    @Test func decodedFramesMatchAVAudioFileForWAV() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        let expected = try Self.fileSamples(wav.url)
        var policy = ProgressiveReadPolicy()
        policy.waitWindowBytes = 0
        let source = TrickleByteSource(data: wav.data, available: Int64(wav.data.count))
        let reader = try await ProgressiveAudioReader.open(source, policy: policy)
        try await reader.setClientFormat(Self.stereo.streamDescription.pointee)
        #expect(reader.lengthFrames == expected.frames)
        let samples = try await ProgressiveFixtures.onThread { try? Self.readAll(reader) } ?? []
        #expect(samples == expected.left)
        reader.close()
    }

    @Test func decodedFramesMatchAVAudioFileForAAC() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m4a = try ProgressiveFixtures.m4a(in: dir)
        let expected = try Self.fileSamples(m4a.url)
        var policy = ProgressiveReadPolicy()
        policy.waitWindowBytes = 0
        let source = TrickleByteSource(data: m4a.data, pathExtension: "m4a", available: Int64(m4a.data.count))
        let reader = try await ProgressiveAudioReader.open(source, policy: policy)
        try await reader.setClientFormat(Self.stereo.streamDescription.pointee)
        #expect(reader.isOpen)
        #expect(reader.lengthFrames == expected.frames)
        let samples = try await ProgressiveFixtures.onThread { try? Self.readAll(reader) } ?? []
        #expect(samples == expected.left)
        // Where CoreAudio put `moov` decides whether the open needed a range request.
        let header = reader.dataOffset
        print("[#0039] m4a: \(m4a.data.count) bytes, dataOffset \(header), side-fetched \(reader.sideFetchedBytes) bytes, ranges \(source.fetchedRanges)")
        reader.close()
    }

    @Test func seekRestartsFromTheFrame() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        let expected = try Self.fileSamples(wav.url)
        let source = TrickleByteSource(data: wav.data, available: Int64(wav.data.count))
        let reader = try await ProgressiveAudioReader.open(source)
        try await reader.setClientFormat(Self.stereo.streamDescription.pointee)
        let samples = try await ProgressiveFixtures.onThread { () -> [Float]? in
            do {
                try reader.seek(toFrame: 11025)
                return try Self.readAll(reader)
            } catch { return nil }
        } ?? []
        #expect(samples == Array(expected.left[11025...]))
        reader.close()
    }

    @Test func aFailedDownloadSurfacesTheError() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        let source = TrickleByteSource(data: wav.data, available: 12288)
        let reader = try await ProgressiveAudioReader.open(source)
        try await reader.setClientFormat(Self.stereo.streamDescription.pointee)
        let outcome = Flag()
        let failure = Counter()
        let thread = Thread {
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 1024)!
            do { while try reader.read(into: buffer) > 0 {} } catch {
                if error is ProgressiveTestError { failure.add(1) }
            }
            outcome.set()
        }
        thread.start()
        #expect(await waitFor { source.waitCount > 0 })
        source.fail(ProgressiveTestError())
        #expect(await waitFor { outcome.isSet })
        #expect(failure.value == 1)
        reader.close()
    }

    @Test func cancellingAnOpenReturnsPromptly() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        let source = TrickleByteSource(data: wav.data, available: 0)
        let task = Task { try await ProgressiveAudioReader.open(source) }
        #expect(await waitFor { source.waitCount > 0 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(source.isCancelled)
    }

    @Test func aFarJumpBeyondTheBudgetIsNotStreamable() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        var policy = ProgressiveReadPolicy()
        policy.maxSideFetchBytes = 0
        policy.waitWindowBytes = 0
        let source = TrickleByteSource(data: wav.data, available: 0)
        do {
            _ = try await ProgressiveAudioReader.open(source, policy: policy)
            Issue.record("open should have given up")
        } catch let error as ProgressiveError {
            guard case .notStreamable = error else { Issue.record("wrong error \(error)"); return }
            #expect(error.isFallbackTrigger)
        }
    }

    @Test func aFarJumpWithinTheBudgetIsOneRangeRequest() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        var policy = ProgressiveReadPolicy()
        policy.waitWindowBytes = 0
        policy.sideFetchGranularity = 4096
        // Nothing has arrived, but the whole file is available by range: the header comes from the side cache.
        let source = TrickleByteSource(data: wav.data, available: 0)
        let reader = try await ProgressiveAudioReader.open(source, policy: policy)
        #expect(reader.lengthFrames == 22050)
        #expect(!source.fetchedRanges.isEmpty)
        #expect(reader.sideFetchedBytes > 0)
        reader.close()
    }

    @Test func invalidBytesFailTheOpenWithoutAFallbackError() async throws {
        let source = TrickleByteSource(data: ProgressiveFixtures.randomData(4096), available: 12288)
        do {
            _ = try await ProgressiveAudioReader.open(source)
            Issue.record("random bytes opened")
        } catch let error as ProgressiveError {
            #expect(!error.isFallbackTrigger)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func bufferedFramesIsProportionalAndCompleteAtTheEnd() async throws {
        let dir = try ProgressiveFixtures.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try ProgressiveFixtures.wav(in: dir)
        var policy = ProgressiveReadPolicy()
        policy.prerollSeconds = 0.05
        let source = TrickleByteSource(data: wav.data, available: 12288)
        let reader = try await ProgressiveAudioReader.open(source, policy: policy)
        source.advance(toFraction: 0.5)
        let half = reader.bufferedFrames()
        let expected = 11025 - Int64(0.05 * 44100)
        #expect(abs(half - expected) < 2205, "buffered \(half), expected about \(expected)")
        source.advance(to: source.finalSize)
        #expect(reader.bufferedFrames() == 22050)
        reader.close()
    }
}

/// Polls until `condition` holds (up to `timeout` seconds).
func waitFor(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
