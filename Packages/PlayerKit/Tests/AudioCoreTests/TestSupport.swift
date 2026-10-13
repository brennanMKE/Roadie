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

/// A `TrackResolver` whose `localURL(for:)` suspends until the test calls `release`, so a load can be
/// held in flight without an engine. With `honorsCancellation` (default) a cancelled load resumes with
/// `CancellationError`; pass `false` to model a resolver that ignores cancellation, so the stale result
/// still arrives and the player's generation check is what must discard it.
actor GateResolver: TrackResolver {
    private(set) var calls: [Track.ID] = []
    private var waiters: [(waiter: UUID, track: Track.ID, continuation: CheckedContinuation<URL, any Error>)] = []
    private var cancelledEarly: Set<UUID> = []
    private let honorsCancellation: Bool

    init(honorsCancellation: Bool = true) { self.honorsCancellation = honorsCancellation }

    func localURL(for track: Track) async throws -> URL {
        calls.append(track.id)
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledEarly.remove(waiter) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((waiter, track.id, continuation))
                }
            }
        } onCancel: {
            if self.honorsCancellation { Task { await self.cancel(waiter) } }
        }
    }

    private func cancel(_ waiter: UUID) {
        if let index = waiters.firstIndex(where: { $0.waiter == waiter }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledEarly.insert(waiter)
        }
    }

    /// Resumes the oldest pending call for `id`.
    func release(_ id: Track.ID, with result: Result<URL, any Error>) {
        guard let index = waiters.firstIndex(where: { $0.track == id }) else { return }
        waiters.remove(at: index).continuation.resume(with: result)
    }

    /// Fails everything still pending so no continuation leaks when a test ends.
    func releaseAll() {
        for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        waiters = []
    }

    /// Waits (up to ~2 s) until the resolver has been called `count` times.
    func waitForCalls(_ count: Int) async -> Bool {
        for _ in 0..<200 where calls.count < count { try? await Task.sleep(for: .milliseconds(10)) }
        return calls.count >= count
    }
}
