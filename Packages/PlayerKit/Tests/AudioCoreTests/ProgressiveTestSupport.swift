import AVFoundation
import Foundation
import os
@testable import AudioCore

struct ProgressiveTestError: LocalizedError, Equatable {
    var errorDescription: String? { "boom: the download failed" }
}

/// A `ProgressiveByteSource` over a complete file whose bytes "arrive" when the test says so. `waitForBytes`
/// blocks on a condition, so a read is held exactly as long as the test wants and no timing is involved.
final class TrickleByteSource: ProgressiveByteSource, @unchecked Sendable {
    let data: Data
    let pathExtension: String
    private let condition = NSCondition()
    private var available: Int64
    private var failure: (any Error)?
    private var cancelled = false
    private var closed = false
    private var ranges: [Range<Int64>] = []
    private var waits = 0
    private var reads: [String] = []
    private let created = Date()
    /// A test that would hang fails after this many seconds instead.
    static let lifetime: TimeInterval = 25

    init(data: Data, pathExtension: String = "wav", available: Int64 = 0) {
        self.data = data
        self.pathExtension = pathExtension
        self.available = available
    }

    var finalSize: Int64 { Int64(data.count) }
    var availableBytes: Int64 { condition.withLock { available } }
    var isClosed: Bool { condition.withLock { closed } }
    var isCancelled: Bool { condition.withLock { cancelled } }
    var fetchedRanges: [Range<Int64>] { condition.withLock { ranges } }
    /// How many times a reader blocked on bytes that had not arrived.
    var readTrace: [String] { condition.withLock { reads } }
    var waitCount: Int { condition.withLock { waits } }

    func advance(to bytes: Int64) {
        condition.lock()
        available = min(max(available, bytes), finalSize)
        condition.broadcast()
        condition.unlock()
    }

    func advance(toFraction fraction: Double) { advance(to: Int64(Double(finalSize) * fraction)) }

    func fail(_ error: any Error) {
        condition.lock()
        failure = error
        condition.broadcast()
        condition.unlock()
    }

    func waitForBytes(through end: Int64, timeout: TimeInterval) -> ProgressiveWaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        if available >= end { return .available }
        waits += 1
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if available >= end { return .available }
            if let failure { return .failed(failure) }
            if cancelled || closed { return .cancelled }
            if Date().timeIntervalSince(created) > Self.lifetime { return .failed(ProgressiveTestError()) }
            if !condition.wait(until: deadline) { return .timedOut }
        }
    }

    func read(into buffer: UnsafeMutableRawPointer, offset: Int64, count: Int) throws -> Int {
        condition.withLock { reads.append("\(offset)+\(count)") }
        let start = Int(offset)
        let end = min(start + count, data.count)
        guard start < end else { return 0 }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: start..<end)
        return end - start
    }

    func fetchRange(_ range: Range<Int64>) throws -> Data {
        condition.withLock { ranges.append(range) }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// The marker URL resolves to the trickling source; real files resolve to themselves.
final class TrickleResolver: TrackResolver, @unchecked Sendable {
    static let marker = URL(filePath: "/trickle/progressive.wav")
    let source: TrickleByteSource
    let wholeFile: URL

    init(source: TrickleByteSource, wholeFile: URL) {
        self.source = source
        self.wholeFile = wholeFile
    }

    func localURL(for track: Track) async throws -> URL {
        guard case .file(let url) = track.source, url != Self.marker else { return wholeFile }
        return url
    }

    func resolve(_ track: Track) async throws -> ResolvedAudio {
        guard case .file(let url) = track.source, url != Self.marker else { return .progressive(source) }
        return .file(url)
    }

    static func progressiveTrack(for source: TrickleByteSource, duration: TimeInterval = 0.5) -> Track {
        Track(title: "progressive", artist: "", duration: duration, source: .file(Self.marker))
    }
}

enum ProgressiveFixtures {
    static let frames = 22050
    static let rate = 44100.0

    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "progressive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 0.5 s stereo 441 Hz float WAV (the same sine `GaplessRenderTests` writes).
    static func wav(in dir: URL, name: String = "tone.wav", hz: Double = 441) throws -> (url: URL, data: Data) {
        let url = dir.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for ch in 0..<2 {
                let samples = buffer.floatChannelData![ch]
                for i in 0..<frames { samples[i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate)) }
            }
            try file.write(from: buffer)
        }   // closed here so the header is final
        return (url, try Data(contentsOf: url))
    }

    /// A 0.5 s AAC `.m4a` written by CoreAudio.
    static func m4a(in dir: URL, name: String = "tone.m4a") throws -> (url: URL, data: Data) {
        let url = dir.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for ch in 0..<2 {
                let samples = buffer.floatChannelData![ch]
                for i in 0..<frames { samples[i] = Float(0.5 * sin(2 * .pi * 441 * Double(i) / rate)) }
            }
            try file.write(from: buffer)
        }   // closed here: the moov atom is finalized
        return (url, try Data(contentsOf: url))
    }

    static func randomData(_ count: Int) -> Data {
        var rng = SplitMix64(seed: 39)
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// Runs blocking work on a plain thread (the reader's calls block; never on a cooperative thread).
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.start()
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { lock.withLock { $0 } }
    func add(_ n: Int) { lock.withLock { $0 += n } }
}

final class Flag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { lock.withLock { $0 } }
    func set() { lock.withLock { $0 = true } }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
