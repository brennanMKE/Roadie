import AVFoundation
import Foundation
@testable import AudioCore

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func makeTracks(_ n: Int, from start: Int = 0) -> [Track] {
    (start..<(start + n)).map {
        Track(title: "t\($0)", artist: "", duration: 1, source: .file(URL(filePath: "/tmp/t\($0).wav")))
    }
}

func queue(_ n: Int) -> PlayQueue { PlayQueue(tracks: makeTracks(n)) }

/// Polls `condition` every 10 ms until it holds or `timeoutMillis` passes.
@MainActor
func waitUntil(timeoutMillis: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMillis)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Puts the player's engine in offline manual rendering mode, so `play()` drives the graph without
/// opening the output device. Nothing renders unless the test pulls with `renderOffline`, and
/// `.dataPlayedBack` completions never fire, so track advance needs a real-time test (`RealtimeAudio`).
@MainActor
func renderSilently(_ player: Player) throws {
    let engine = player.ensureGraph().engine
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
}
