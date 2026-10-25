import AVFoundation
import Foundation
import PlayerKitTestFixtures
import Testing
@testable import AudioCore

/// The committed fixtures (#0195): real MP3, AAC, ALAC, FLAC and WAV files, decoded and rendered offline.
@MainActor
@Suite struct AudioFixtureDecodeTests {
    typealias File = AudioFixtures.File

    /// Every frame `AVAudioFile` (the player's reader) decodes from `url`.
    static func decodedFrames(_ url: URL) throws -> (frames: Int, rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var frames = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            frames += Int(buffer.frameLength)
        }
        return (frames, file.processingFormat.sampleRate)
    }

    /// Plays `files` through a `Player` in offline manual rendering and returns `frames` left-channel samples.
    /// Offline, only the current file and the pre-scheduled next one are on the node, so at most two files render.
    static func render(_ files: [File], frames: Int) async throws -> [Float] {
        let player = Player()
        player.enqueue(try files.map { try Track.file(at: AudioFixtures.url($0)) })
        try renderSilently(player)
        let engine = player.ensureGraph().engine
        player.play()
        if files.count > 1 {
            #expect(await waitUntil { player.hasPreScheduledNext })
        } else {
            #expect(await waitUntil { player.state == .playing })
        }
        #expect(player.errorMessage == nil)
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var samples: [Float] = []
        samples.reserveCapacity(frames + 512)
        while samples.count < frames {
            #expect(try engine.renderOffline(512, to: out) == .success)
            samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
            if samples.count % 8192 == 0 { await Task.yield() }
        }
        player.stop()
        return samples
    }

    /// Sign changes in `samples[range]`: twice the frequency times the window length for a clean sine.
    static func zeroCrossings(_ samples: [Float], _ range: Range<Int>) -> Int {
        var count = 0
        for i in range.dropFirst() where (samples[i - 1] < 0) != (samples[i] < 0) { count += 1 }
        return count
    }

    /// The longest run of near-zero samples in `samples[range]`.
    static func longestQuietRun(_ samples: [Float], _ range: ClosedRange<Int>, below: Float = 0.001) -> Int {
        var longest = 0, run = 0
        for i in range {
            if abs(samples[i]) < below { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return longest
    }

    @Test func everyFixtureDecodesOffline() async throws {
        let manifest = try AudioFixtures.manifest()
        for file in File.allCases {
            let entry = try #require(manifest[file.rawValue], "\(file.rawValue) missing from MANIFEST.txt")
            let track = try await LocalTrackLoader.loadTrack(at: AudioFixtures.url(file))
            #expect(abs(track.duration - entry.seconds) < 0.1, "\(file.rawValue): duration \(track.duration), manifest \(entry.seconds)")
            #expect(track.sampleRate == 44_100, "\(file.rawValue)")
            #expect(track.channels == 2, "\(file.rawValue)")

            let (frames, rate) = try Self.decodedFrames(AudioFixtures.url(file))
            let expected = entry.seconds * rate
            if file.rawValue.hasSuffix(".mp3") {
                // lame's LAME/Xing header carries the encoder delay and padding, and Core Audio trims both.
                #expect(frames == Int(expected), "\(file.rawValue): \(frames) frames, expected \(Int(expected))")
            } else {
                #expect(abs(Double(frames) - expected) <= expected * 0.01, "\(file.rawValue): \(frames) frames, expected \(Int(expected))")
            }
        }
    }

    @Test func tagsAreRead() async throws {
        for file in [File.toneAmp3, .toneBmp3, .toneCaac, .toneDalac] {
            let track = try await LocalTrackLoader.loadTrack(at: AudioFixtures.url(file))
            #expect(track.title == file.title, "\(file.rawValue)")
            #expect(track.artist == AudioFixtures.artist, "\(file.rawValue)")
            #expect(track.album == AudioFixtures.album, "\(file.rawValue)")
        }
        // The FLAC carries Vorbis comments, but AVFoundation lists them only under `vorb/` keys, not in the common
        // metadata `LocalTrackLoader` reads, so the FLAC gets the file-name fallback title and no artist.
        let flac = try await LocalTrackLoader.loadTrack(at: AudioFixtures.url(.toneEflac))
        #expect(flac.title == "05 Tone E")
        #expect(flac.artist == "")
        let wav = try await LocalTrackLoader.loadTrack(at: AudioFixtures.url(.toneFwav))
        #expect(wav.title == "06 Tone F")
    }

    @Test func gaplessMP3JoinHasNoSilence() async throws {
        let lengthA = try Self.decodedFrames(AudioFixtures.url(.toneAmp3)).frames
        let lengthB = try Self.decodedFrames(AudioFixtures.url(.toneBmp3)).frames
        let samples = try await Self.render([.toneAmp3, .toneBmp3], frames: lengthA + lengthB + 8192)

        let first = try #require(samples.firstIndex { abs($0) > 0.01 })
        let last = try #require(samples.lastIndex { abs($0) > 0.01 })
        let join = first + lengthA
        #expect(abs((last - first + 1) - (lengthA + lengthB)) <= 1024, "audible span \(last - first + 1)")

        // 5 ms at 44.1 kHz. A sine passes zero in one or two samples; a gap shows as a long quiet run.
        let quiet = Self.longestQuietRun(samples, (join - 2205)...(join + 2205))
        #expect(quiet <= 220, "\(quiet) near-zero samples at the join")
        #expect(Self.longestQuietRun(samples, first...last) <= 220)

        // 50 ms windows 100 ms either side of the join: 440 Hz gives 44 crossings, 660 Hz gives 66.
        let before = Self.zeroCrossings(samples, (join - 4410 - 2205)..<(join - 4410))
        let after = Self.zeroCrossings(samples, (join + 4410)..<(join + 4410 + 2205))
        #expect(abs(before - 44) <= 3, "before the join: \(before) crossings")
        #expect(abs(after - 66) <= 3, "after the join: \(after) crossings")
    }

    @Test func mixedFormatQueueRenders() async throws {
        // WAV → AAC → FLAC → ALAC → MP3, one join at a time (offline, only two files reach the node).
        let order: [File] = [.toneFwav, .toneCaac, .toneEflac, .toneDalac, .toneAmp3]
        for (a, b) in zip(order, order.dropFirst()) {
            let lengthA = try Self.decodedFrames(AudioFixtures.url(a)).frames
            let lengthB = try Self.decodedFrames(AudioFixtures.url(b)).frames
            let samples = try await Self.render([a, b], frames: lengthA + lengthB + 8192)
            var peaks: [Float] = []
            var start = 0
            while start + 512 <= samples.count {
                peaks.append(samples[start..<(start + 512)].reduce(0) { max($0, abs($1)) })
                start += 512
            }
            let first = try #require(peaks.firstIndex { $0 > 0.005 }, "\(a.rawValue) → \(b.rawValue)")
            let last = try #require(peaks.lastIndex { $0 > 0.005 }, "\(a.rawValue) → \(b.rawValue)")
            let audible = (last - first + 1) * 512
            #expect(abs(audible - (lengthA + lengthB)) <= 2048, "\(a.rawValue) → \(b.rawValue): span \(audible)")
            #expect(peaks[first...last].allSatisfy { $0 > 0.005 }, "\(a.rawValue) → \(b.rawValue): silent block")
        }
    }

    /// Opt-in with `ROADIE_SLOW_TESTS=1` (the VM's full tier, `--full`): every fixture through the whole `Player`
    /// graph, the analyzer's peak column at the tone's frequency and the audible length matching the decode.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROADIE_SLOW_TESTS"] == "1"))
    func fixtureCorpusDecodesEndToEnd() async throws {
        for file in File.allCases {
            let length = try Self.decodedFrames(AudioFixtures.url(file)).frames
            let player = Player()
            player.enqueue([try Track.file(at: AudioFixtures.url(file))])
            try renderSilently(player)
            let engine = player.ensureGraph().engine
            player.play()
            #expect(await waitUntil { player.state == .playing && player.analyzer.isInstalled }, "\(file.rawValue)")
            let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
            var samples: [Float] = []
            func pull(_ blocks: Int) async throws {
                for i in 0..<blocks {
                    _ = try engine.renderOffline(512, to: out)
                    samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
                    if i % 8 == 0 { try await Task.sleep(for: .milliseconds(10)) }
                }
            }
            // A third of the shortest file (0.5 s), so the analyzer's latest frame is inside the tone.
            try await pull(14)
            try await Task.sleep(for: .milliseconds(50))
            #expect(await waitUntil { player.analyzer.latestFrame() != nil }, "\(file.rawValue)")
            let frame = try #require(player.analyzer.latestFrame(), "\(file.rawValue)")
            let map = try #require(player.analyzer.columnMap)
            let peak = try #require(frame.spectrum.indices.max { frame.spectrum[$0] < frame.spectrum[$1] })
            #expect(map.ranges[peak].contains(map.bin(forFrequency: file.hz)), "\(file.rawValue): peak column \(peak)")

            try await pull((length + 8192) / 512 - 14 + 1)
            let first = try #require(samples.firstIndex { abs($0) > 0.01 }, "\(file.rawValue)")
            let last = try #require(samples.lastIndex { abs($0) > 0.01 }, "\(file.rawValue)")
            #expect(abs((last - first + 1) - length) <= 1024, "\(file.rawValue): audible \(last - first + 1) of \(length)")
            player.stop()
            player.analyzer.remove()
        }
    }
}
