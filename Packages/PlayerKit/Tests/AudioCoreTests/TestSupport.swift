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
