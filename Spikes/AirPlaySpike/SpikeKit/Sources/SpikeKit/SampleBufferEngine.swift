@preconcurrency import AVFoundation
import AVKit
import CoreMedia
import Foundation

/// What the feed queue and KVO callbacks touch. Everything here is either immutable or internally locked.
private final class FeedContext: @unchecked Sendable {
    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer
    let log: SpikeLog
    let queue = DispatchQueue(label: "com.brennanmke.AirPlaySpike.feed")
    let lock = NSLock()
    private var _source: PCMSource?
    init(renderer: AVSampleBufferAudioRenderer, synchronizer: AVSampleBufferRenderSynchronizer, log: SpikeLog) {
        self.renderer = renderer
        self.synchronizer = synchronizer
        self.log = log
    }
    var source: PCMSource? {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; lock.unlock() }
    }
}

/// Engines B and B-dev: one AVSampleBufferAudioRenderer on one AVSampleBufferRenderSynchronizer, fed decoded PCM.
/// The classic request/enqueue API is deprecated in macOS 27; the deployment target is 14, so it is used as is.
@MainActor
public final class SampleBufferEngine: SpikeEngine {
    public let kind: EngineKind
    private let log: SpikeLog
    private let ctx: FeedContext
    private var source: PCMSource?
    private var meter = LeadMeter()
    private weak var picker: AVRoutePickerView?
    private var readyObservation: NSKeyValueObservation?
    public var deviceUID: String?

    public init(kind: EngineKind, log: SpikeLog, deviceUID: String? = nil) {
        precondition(kind == .b || kind == .bDevice)
        self.kind = kind
        self.log = log
        self.deviceUID = deviceUID
        let renderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        ctx = FeedContext(renderer: renderer, synchronizer: synchronizer, log: log)
    }

    public func load(_ urls: [URL]) throws {
        let source = try PCMSource(urls: urls)
        self.source = source
        ctx.source = source
        log.log(kind.shortName, "load \(urls.count) file(s), \(source.totalDuration) s")
    }

    private func installFeed() {
        let ctx = self.ctx
        let name = kind.shortName
        // play() after pause() reinstalls the feed; never leave two requests pending on one renderer.
        ctx.renderer.stopRequestingMediaData()
        ctx.renderer.requestMediaDataWhenReady(on: ctx.queue) {
            guard let source = ctx.source else { ctx.renderer.stopRequestingMediaData(); return }
            while ctx.renderer.isReadyForMoreMediaData {
                guard let buffer = source.next() else {
                    ctx.renderer.stopRequestingMediaData()
                    ctx.log.log(name, "end of data, last enqueued \(source.lastEnqueuedEnd)")
                    return
                }
                ctx.renderer.enqueue(buffer)
            }
        }
        readyObservation = ctx.renderer.observe(\.isReadyForMoreMediaData, options: [.new]) { _, change in
            let lead = (ctx.source?.lastEnqueuedEnd ?? 0) - ctx.synchronizer.currentTime().seconds
            ctx.log.log(name, "isReadyForMoreMediaData \(change.newValue ?? false) lead \(lead)")
        }
    }

    public func play() {
        if kind == .bDevice, let deviceUID {
            ctx.renderer.audioOutputDeviceUniqueID = deviceUID
            log.log(kind.shortName, "audioOutputDeviceUniqueID = \(deviceUID)")
        }
        log.log(kind.shortName, "play")
        installFeed()
        ctx.synchronizer.setRate(1, time: ctx.synchronizer.currentTime())
    }

    public func pause() {
        log.log(kind.shortName, "pause")
        ctx.synchronizer.setRate(0, time: ctx.synchronizer.currentTime())
    }

    public func seek(by seconds: TimeInterval) {
        guard let source else { return }
        let target = max(0, ctx.synchronizer.currentTime().seconds + seconds)
        log.log(kind.shortName, "seek to \(target); renderer status \(ctx.renderer.status.rawValue)")
        ctx.synchronizer.setRate(0, time: ctx.synchronizer.currentTime())
        ctx.renderer.stopRequestingMediaData()
        ctx.renderer.flush()
        source.seek(to: target)
        installFeed()
        ctx.synchronizer.setRate(1, time: CMTime(seconds: target, preferredTimescale: 48_000))
        log.log(kind.shortName, "seek done; renderer status \(ctx.renderer.status.rawValue) error \(ctx.renderer.error?.localizedDescription ?? "none")")
    }

    public func next() {
        guard let source else { return }
        let now = ctx.synchronizer.currentTime().seconds
        var i = 0
        while i < source.trackCount, source.startOfTrack(i + 1) <= now { i += 1 }
        let target = source.startOfTrack(i + 1)
        guard i + 1 < source.trackCount else { log.log(kind.shortName, "next: no further track"); return }
        log.log(kind.shortName, "next to \(target)")
        seek(by: target - now)
    }

    public var volume: Float {
        get { ctx.renderer.volume }
        set { ctx.renderer.volume = newValue }
    }

    public var currentTime: TimeInterval { ctx.synchronizer.currentTime().seconds }
    public var rate: Float { ctx.synchronizer.rate }

    public var leadSeconds: TimeInterval? {
        guard let source else { return nil }
        meter.record(lastEnqueued: source.lastEnqueuedEnd, now: currentTime, at: .now)
        return meter.current
    }

    public var leadMeter: LeadMeter { meter }
    public var isReadyForMoreMediaData: Bool { ctx.renderer.isReadyForMoreMediaData }

    public func attach(to picker: AVRoutePickerView) {
        self.picker = picker
        picker.player = nil
        log.log(kind.shortName, "attach picker.player nil")
    }

    public func detach() {
        picker?.player = nil
        picker = nil
        log.log(kind.shortName, "detach")
    }

    public func probe() -> [ProbeLine] {
        [
            ("isReadyForMoreMediaData", "\(ctx.renderer.isReadyForMoreMediaData)"),
            ("rendererStatus", "\(ctx.renderer.status.rawValue)"),
            ("rendererError", ctx.renderer.error?.localizedDescription ?? "none"),
            ("audioOutputDeviceUniqueID", ctx.renderer.audioOutputDeviceUniqueID ?? "default"),
            ("synchronizerRate", "\(ctx.synchronizer.rate)"),
            ("synchronizerTime", "\(ctx.synchronizer.currentTime().seconds)"),
            ("lastEnqueuedEnd", "\(source?.lastEnqueuedEnd ?? 0)"),
        ]
    }

    public func teardown() {
        ctx.synchronizer.setRate(0, time: ctx.synchronizer.currentTime())
        ctx.renderer.stopRequestingMediaData()
        ctx.renderer.flush()
        readyObservation?.invalidate()
        readyObservation = nil
        ctx.source = nil
        source = nil
        log.log(kind.shortName, "teardown")
    }
}
