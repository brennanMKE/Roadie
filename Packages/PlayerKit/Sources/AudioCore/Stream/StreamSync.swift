import Foundation

/// Tuning for keeping a timed stream in sync (Sendspin's suggested strategy).
struct StreamSyncPolicy: Sendable {
    var deadBandMicros: Int64 = 100
    var snapMicros: Int64 = 10_000
    var maxSpeedFraction: Double = 0.005
    /// How far past "now" a chunk's end may be and still count as playable.
    var lateDropMicros: Int64 = 0
    /// A chunk within this distance of where the previous one ended is contiguous.
    var contiguityMicros: Int64 = 1_000
}

/// Where a chunk goes relative to what is already scheduled.
enum StreamPlacement: Equatable, Sendable {
    /// First chunk (or after a clear): start the node so the first kept frame is heard at `atMicros`.
    case start(atMicros: Int64, dropLeading: Int)
    /// Starts where the previous chunk ended: append.
    case contiguous
    /// Starts later than the previous chunk ended: `silenceMicros` of silence, then the chunk.
    case gap(atMicros: Int64, silenceMicros: Int64)
    /// Starts earlier than the previous chunk ended: drop the duplicate prefix.
    case overlap(dropLeading: Int)
    /// Entirely in the past (or entirely a duplicate): dropped.
    case late
}

/// The stream's timeline: where the next contiguous chunk should start and what has been scheduled.
struct StreamTimeline: Sendable {
    var policy = StreamSyncPolicy()
    /// Local time at which the first kept frame since the last start is heard.
    private(set) var anchorMicros: Int64?
    /// Where the next contiguous chunk should start (nil before the first chunk or after a reset).
    private(set) var nextChunkMicros: Int64?
    /// Source frames scheduled since the last start.
    private(set) var framesScheduled: Int = 0
    private(set) var lateChunks: Int = 0
    private(set) var gaps: Int = 0

    mutating func reset() {
        anchorMicros = nil
        nextChunkMicros = nil
        framesScheduled = 0
    }

    static func micros(frames: Int, rate: Double) -> Int64 { Int64((Double(frames) / rate * 1e6).rounded()) }

    /// `nowMicros` is the earliest time audio scheduled now can be heard (now + output latency).
    mutating func place(_ chunkMicros: Int64, frames: Int, nowMicros: Int64, rate: Double) -> StreamPlacement {
        guard frames > 0, rate > 0 else { return .late }
        let duration = Self.micros(frames: frames, rate: rate)
        let end = chunkMicros + duration
        if end <= nowMicros + policy.lateDropMicros {
            lateChunks += 1
            return .late
        }
        guard let next = nextChunkMicros else {
            var drop = 0
            if chunkMicros < nowMicros {
                drop = min(frames - 1, Int((Double(nowMicros - chunkMicros) * rate / 1e6).rounded(.up)))
            }
            let at = chunkMicros + Self.micros(frames: drop, rate: rate)
            anchorMicros = at
            nextChunkMicros = end
            framesScheduled = frames - drop
            return .start(atMicros: at, dropLeading: drop)
        }
        let delta = chunkMicros - next
        if abs(delta) <= policy.contiguityMicros {
            nextChunkMicros = end
            framesScheduled += frames
            return .contiguous
        }
        if delta > 0 {
            gaps += 1
            nextChunkMicros = end
            framesScheduled += frames
            return .gap(atMicros: chunkMicros, silenceMicros: delta)
        }
        let drop = Int((Double(-delta) * rate / 1e6).rounded())
        guard drop < frames else {
            lateChunks += 1
            return .late
        }
        nextChunkMicros = end
        framesScheduled += frames - drop
        return .overlap(dropLeading: drop)
    }
}

enum StreamCorrection: Equatable, Sendable {
    case none
    case drop(Int)
    case duplicate(Int)
    case snap
}

/// Turns a measured sync error into a small per-chunk correction.
struct StreamDriftCorrector: Sendable {
    var policy = StreamSyncPolicy()
    private(set) var snaps = 0

    /// `errorMicros` = actual output time of a frame − its stamped time (positive: playing late → drop).
    mutating func correction(errorMicros: Int64, chunkFrames: Int, rate: Double) -> StreamCorrection {
        let magnitude = abs(errorMicros)
        if magnitude <= policy.deadBandMicros { return .none }
        if magnitude > policy.snapMicros {
            snaps += 1
            return .snap
        }
        let step = max(1, Int((21e-6 * rate).rounded()))
        let cap = Int((policy.maxSpeedFraction * Double(chunkFrames)).rounded(.down))
        let n = min(step, cap)
        guard n > 0 else { return .none }
        return errorMicros > 0 ? .drop(n) : .duplicate(n)
    }
}
