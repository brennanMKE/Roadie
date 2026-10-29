import Accelerate
import AVFoundation
import CAtomics

/// Taps an audio node, hands mono samples to the UI through a lock-free ring, and runs the FFT
/// on the consumer's tick. The tap block allocates nothing and takes no locks.
///
/// Threading: `install`, `remove` and `latestFrame` are called from one thread (the main actor in
/// the app). Only the tap block runs elsewhere, and it touches nothing but the ring and scratch.
public final class AnalyzerTap: @unchecked Sendable {
    public let fftSize: Int
    public var ring: VisSampleRing { sink.ring }
    public private(set) var isInstalled = false
    /// Sample rate the current analyzer was built for (0 before the first install).
    public private(set) var sampleRate: Double = 0
    /// Interleaved L R copy of the signal for the visualization window; written only while enabled.
    public var stereo: VisSampleRing { sink.stereo }
    /// Sample rate of the last `prepare` (same as `sampleRate`, kept separate so `StereoFeedReader`
    /// can notice a change without touching the mono analyzer).
    public private(set) var stereoSampleRate: Double = 0

    private weak var node: AVAudioNode?
    private var bus: AVAudioNodeBus = 0
    private var analyzer: SpectrumAnalyzer?
    /// Producer state owned by the tap block, so the block never retains this object.
    private let sink: TapSink
    private let window: UnsafeMutablePointer<Float>
    private let spectrumOut: UnsafeMutablePointer<Float>
    private let scopeOut: UnsafeMutablePointer<Float>
    private var cached: VisFrame?
    private var cachedEnd: Int?
    private var cursor: VisReadCursor

    public init(fftSize: Int = 1024, ringCapacity: Int = 32_768) {
        self.fftSize = fftSize
        let sink = TapSink(ring: VisSampleRing(capacity: ringCapacity), stereo: VisSampleRing(capacity: 32_768))
        self.sink = sink
        cursor = VisReadCursor(window: fftSize, readable: sink.ring.capacity - sink.ring.maxChunk)
        window = .allocate(capacity: fftSize)
        window.initialize(repeating: 0, count: fftSize)
        spectrumOut = .allocate(capacity: VisFrame.columnCount)
        spectrumOut.initialize(repeating: 0, count: VisFrame.columnCount)
        scopeOut = .allocate(capacity: VisFrame.scopeLength)
        scopeOut.initialize(repeating: 0, count: VisFrame.scopeLength)
    }

    deinit {
        remove()
        window.deallocate(); spectrumOut.deallocate(); scopeOut.deallocate()
    }

    /// Installs (or re-installs) the tap. Safe to call repeatedly, including after an engine
    /// restart: an existing tap is removed first, so there is never a double install. Does not
    /// touch the graph's connections. `sampleRate` builds the column map (the mixer's reported
    /// rate can be stale before the engine runs, so the caller passes the processing rate).
    /// Nonisolated on purpose: a tap closure created in a main-actor context traps on the audio queue.
    public nonisolated func install(on node: AVAudioNode, bus: AVAudioNodeBus = 0, sampleRate: Double) {
        remove()
        prepare(sampleRate: sampleRate)
        self.node = node
        self.bus = bus
        let sink = self.sink
        node.installTap(onBus: bus, bufferSize: 1024, format: nil) { buffer, _ in
            sink.handle(buffer)
        }
        isInstalled = true
    }

    /// Builds the analyzer for `sampleRate` and resets the read cursor. `install` calls this; tests call it
    /// directly to drive the ring without an engine.
    nonisolated func prepare(sampleRate: Double) {
        if sampleRate > 0, sampleRate != self.sampleRate || analyzer == nil {
            analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate)
            self.sampleRate = sampleRate
        }
        if sampleRate > 0 { stereoSampleRate = sampleRate }
        resetCursor()
    }

    /// Turns the stereo ring on or off. Off by default, so the tap does only the mono work until a
    /// visualization renders.
    public nonisolated func setStereoEnabled(_ on: Bool) { sink.setStereoEnabled(on) }

    public var isStereoEnabled: Bool { sink.isStereoEnabled }

    /// Runs the real tap body on `buffer` without an engine (tests).
    func deliver(_ buffer: AVAudioPCMBuffer) { sink.handle(buffer) }

    /// Call when the UI pauses or resumes so the cursor re-lags instead of replaying old audio.
    public nonisolated func resetCursor() {
        cursor.reset()
        cachedEnd = nil
    }

    public nonisolated func remove() {
        guard isInstalled else { return }
        // A node without an engine has already lost its tap; removeTap would raise.
        if let node, node.engine != nil { node.removeTap(onBus: bus) }
        node = nil
        isInstalled = false
    }

    /// Consumer side, ~30-60 Hz. nil until `fftSize` samples have flowed; if the ring was
    /// overwritten mid-copy the previous frame is returned.
    public func latestFrame() -> VisFrame? {
        guard let analyzer else { return nil }
        let count = ring.writeCount
        if let cached, cached.sampleCount == count { return cached }
        guard ring.copyLatest(count: fftSize, into: window) else { return cached }
        analyzer.analyze(UnsafeBufferPointer(start: window, count: fftSize),
                         spectrum: UnsafeMutableBufferPointer(start: spectrumOut, count: VisFrame.columnCount),
                         scope: UnsafeMutableBufferPointer(start: scopeOut, count: VisFrame.scopeLength))
        let frame = VisFrame(
            spectrum: Array(UnsafeBufferPointer(start: spectrumOut, count: VisFrame.columnCount)),
            scope: Array(UnsafeBufferPointer(start: scopeOut, count: VisFrame.scopeLength)),
            sampleCount: count)
        cached = frame
        return frame
    }

    /// Consumer side at display rate. Advances the read cursor by `dt` and analyzes the window ending there.
    /// `VisFrame.sampleCount` is that end index. nil until `fftSize` samples have flowed.
    public func frame(elapsed dt: Double) -> VisFrame? {
        guard let analyzer else { return nil }
        guard let end = cursor.next(writeCount: ring.writeCount, elapsed: dt, sampleRate: sampleRate) else { return cached }
        if end == cachedEnd, let cached { return cached }
        guard ring.copy(count: fftSize, endingAt: end, into: window) else { return cached }
        analyzer.analyze(UnsafeBufferPointer(start: window, count: fftSize),
                         spectrum: UnsafeMutableBufferPointer(start: spectrumOut, count: VisFrame.columnCount),
                         scope: UnsafeMutableBufferPointer(start: scopeOut, count: VisFrame.scopeLength))
        let frame = VisFrame(
            spectrum: Array(UnsafeBufferPointer(start: spectrumOut, count: VisFrame.columnCount)),
            scope: Array(UnsafeBufferPointer(start: scopeOut, count: VisFrame.scopeLength)),
            sampleCount: end)
        cached = frame
        cachedEnd = end
        return frame
    }

    /// Column map for the current sample rate (tests / UI).
    public var columnMap: SpectrumColumnMap? { analyzer?.columnMap }
}

/// Producer side of the tap: the ring plus its scratch buffer. Only the tap block calls `handle`.
private final class TapSink: @unchecked Sendable {
    let ring: VisSampleRing
    let stereo: VisSampleRing
    private let scratch: UnsafeMutablePointer<Float>
    private let stereoScratch: UnsafeMutablePointer<Float>
    /// 1 while the stereo ring is written; release / acquire.
    private let stereoFlag: UnsafeMutablePointer<Int64>

    init(ring: VisSampleRing, stereo: VisSampleRing) {
        self.ring = ring
        self.stereo = stereo
        scratch = .allocate(capacity: ring.capacity)
        scratch.initialize(repeating: 0, count: ring.capacity)
        stereoScratch = .allocate(capacity: stereo.capacity)
        stereoScratch.initialize(repeating: 0, count: stereo.capacity)
        stereoFlag = .allocate(capacity: 1)
        stereoFlag.initialize(to: 0)
    }

    deinit {
        scratch.deallocate()
        stereoScratch.deallocate()
        stereoFlag.deallocate()
    }

    func setStereoEnabled(_ on: Bool) { ca_store_release(stereoFlag, on ? 1 : 0) }

    var isStereoEnabled: Bool { ca_load_acquire(stereoFlag) != 0 }

    /// Tap block body. Preallocated buffers only.
    func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let available = Int(buffer.frameLength)
        guard available > 0 else { return }
        let n = min(available, ring.capacity)
        let skip = available - n
        let left = channels[0] + skip
        if buffer.format.channelCount >= 2 {
            let right = channels[1] + skip
            var half: Float = 0.5
            vDSP_vadd(left, 1, right, 1, scratch, 1, vDSP_Length(n))
            vDSP_vsmul(scratch, 1, &half, scratch, 1, vDSP_Length(n))
        } else {
            memcpy(scratch, left, n * MemoryLayout<Float>.stride)
        }
        ring.write(scratch, count: n)
        guard isStereoEnabled else { return }
        // Newest whole frames, interleaved L R. The ring publishes in maxChunk (capacity / 4, even) slices,
        // so every published slice holds whole frames.
        let frames = min(available, stereo.capacity / 2)
        let stereoSkip = available - frames
        let l = channels[0] + stereoSkip
        let r = buffer.format.channelCount >= 2 ? channels[1] + stereoSkip : l
        var split = DSPSplitComplex(realp: l, imagp: r)
        stereoScratch.withMemoryRebound(to: DSPComplex.self, capacity: frames) { out in
            vDSP_ztoc(&split, 1, out, 2, vDSP_Length(frames))
        }
        stereo.write(stereoScratch, count: 2 * frames)
    }
}
