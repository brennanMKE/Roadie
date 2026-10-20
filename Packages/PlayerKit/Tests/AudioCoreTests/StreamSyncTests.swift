import Testing
@testable import AudioCore

/// The pure core of the timed stream (#0106): where each chunk goes and how drift is corrected.
@Suite struct StreamSyncTests {
    let rate = 48_000.0
    let frames = 960   // 20 ms

    @Test func firstChunkStartsAtItsTimeAndDropsThePastPrefix() {
        var timeline = StreamTimeline()
        #expect(timeline.place(1_000_000, frames: frames, nowMicros: 900_000, rate: rate)
            == .start(atMicros: 1_000_000, dropLeading: 0))
        timeline.reset()
        // 5 ms of the chunk is already past: 240 frames dropped, the first kept one heard "now".
        #expect(timeline.place(1_000_000, frames: frames, nowMicros: 1_005_000, rate: rate)
            == .start(atMicros: 1_005_000, dropLeading: 240))
        #expect(timeline.anchorMicros == 1_005_000)
        #expect(timeline.framesScheduled == 720)
    }

    @Test func contiguousChunkIsAppended() {
        var timeline = StreamTimeline()
        _ = timeline.place(0, frames: frames, nowMicros: 0, rate: rate)
        #expect(timeline.place(20_000, frames: frames, nowMicros: 0, rate: rate) == .contiguous)
        // Within ±1 ms of where the previous chunk ended still counts as contiguous.
        #expect(timeline.place(40_500, frames: frames, nowMicros: 0, rate: rate) == .contiguous)
        #expect(timeline.framesScheduled == 3 * frames)
    }

    @Test func gapReanchorsAndOverlapDropsThePrefix() {
        var timeline = StreamTimeline()
        _ = timeline.place(0, frames: frames, nowMicros: 0, rate: rate)
        #expect(timeline.place(25_000, frames: frames, nowMicros: 0, rate: rate)
            == .gap(atMicros: 25_000, silenceMicros: 5_000))
        // The next chunk should start at 45 000; this one starts 5 ms earlier.
        #expect(timeline.place(40_000, frames: frames, nowMicros: 0, rate: rate) == .overlap(dropLeading: 240))
        #expect(timeline.place(60_000, frames: frames, nowMicros: 0, rate: rate) == .contiguous)
    }

    @Test func entirelyLateChunkIsDropped() {
        var timeline = StreamTimeline()
        #expect(timeline.place(0, frames: frames, nowMicros: 50_000, rate: rate) == .late)
        #expect(timeline.lateChunks == 1)
        #expect(timeline.nextChunkMicros == nil)
        _ = timeline.place(100_000, frames: frames, nowMicros: 50_000, rate: rate)
        #expect(timeline.place(120_000, frames: frames, nowMicros: 200_000, rate: rate) == .late)
        #expect(timeline.lateChunks == 2)
    }

    @Test func correctorStaysInsideTheDeadBand() {
        var corrector = StreamDriftCorrector()
        for error: Int64 in [0, 50, -50, 100, -100] {
            #expect(corrector.correction(errorMicros: error, chunkFrames: frames, rate: rate) == .none)
        }
    }

    @Test func correctorDropsWhenLateAndDuplicatesWhenEarly() {
        var corrector = StreamDriftCorrector()
        #expect(corrector.correction(errorMicros: 500, chunkFrames: frames, rate: rate) == .drop(1))
        #expect(corrector.correction(errorMicros: -500, chunkFrames: frames, rate: rate) == .duplicate(1))
        // 21 µs at 192 kHz is 4 frames.
        #expect(corrector.correction(errorMicros: 500, chunkFrames: 3840, rate: 192_000) == .drop(4))
    }

    @Test func correctionNeverExceedsHalfAPercentOfTheChunk() {
        var corrector = StreamDriftCorrector()
        #expect(corrector.correction(errorMicros: 5_000, chunkFrames: 400, rate: 192_000) == .drop(2))
        #expect(corrector.correction(errorMicros: -5_000, chunkFrames: 400, rate: 192_000) == .duplicate(2))
        #expect(corrector.correction(errorMicros: 5_000, chunkFrames: 100, rate: 48_000) == .none)
    }

    @Test func largeErrorSnaps() {
        var corrector = StreamDriftCorrector()
        #expect(corrector.correction(errorMicros: 10_000, chunkFrames: frames, rate: rate) == .drop(1))
        #expect(corrector.correction(errorMicros: 10_001, chunkFrames: frames, rate: rate) == .snap)
        #expect(corrector.correction(errorMicros: -20_000, chunkFrames: frames, rate: rate) == .snap)
        #expect(corrector.snaps == 2)
    }
}
