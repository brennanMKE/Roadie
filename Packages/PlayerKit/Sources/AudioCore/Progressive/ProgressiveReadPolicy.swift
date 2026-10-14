import Foundation

/// How the progressive reader answers one `AudioFile` read: serve it, wait for the sequential download,
/// range-fetch it, or give up on streaming this file. Pure, so it is tested without CoreAudio.
struct ProgressiveReadPolicy: Sendable {
    /// Reads that start within this many bytes past the frontier wait for the sequential download.
    var waitWindowBytes: Int64 = 4 << 20
    /// Total bytes a reader may fetch by range before giving up on streaming this file.
    var maxSideFetchBytes: Int64 = 8 << 20
    /// Range fetches are rounded out to this granularity and cached in the reader.
    var sideFetchGranularity: Int64 = 64 << 10
    var prerollSeconds: TimeInterval = 2
    var minimumPrerollBytes: Int64 = 256 << 10

    enum Decision: Equatable {
        case serve
        case wait(through: Int64)
        case sideFetch(Range<Int64>)
        case endOfFile
        case giveUp
    }

    /// A read callback must never return a short read before the true end (AudioFile treats it as EOF),
    /// so there is no "serve what you have" case.
    func decide(offset: Int64, count: Int, available: Int64, finalSize: Int64, sideFetched: Int64) -> Decision {
        guard offset < finalSize else { return .endOfFile }
        let end = min(offset + Int64(count), finalSize)
        if end <= available { return .serve }
        if offset < available + waitWindowBytes { return .wait(through: end) }
        if sideFetched + (end - offset) > maxSideFetchBytes { return .giveUp }
        return .sideFetch(offset..<end)
    }

    /// `max(minimumPrerollBytes, bitrateKbps * 125 * prerollSeconds)`, capped at `finalSize`; nil bitrate is 192 kbps.
    func prerollBytes(bitrateKbps: Int?, finalSize: Int64) -> Int64 {
        let kbps = Double(bitrateKbps ?? 192)
        let wanted = max(minimumPrerollBytes, Int64(kbps * 125 * prerollSeconds))
        return min(wanted, finalSize)
    }
}
