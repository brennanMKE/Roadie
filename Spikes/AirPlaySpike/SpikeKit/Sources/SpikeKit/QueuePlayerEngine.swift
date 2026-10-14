@preconcurrency import AVFoundation
import AVKit
import Foundation

/// Engines A, A' and A+tap: an AVQueuePlayer with one item per file.
@MainActor
public final class QueuePlayerEngine: SpikeEngine {
    public let kind: EngineKind
    private let log: SpikeLog
    private let player = AVQueuePlayer()
    private let tap: GainRMSTap?
    private var meter = LeadMeter()
    private weak var picker: AVRoutePickerView?
    private var observers: [NSObjectProtocol] = []
    private var urls: [URL] = []

    public init(kind: EngineKind, log: SpikeLog) {
        precondition(kind == .a || kind == .aPrime || kind == .aTap)
        self.kind = kind
        self.log = log
        tap = kind == .aTap ? GainRMSTap(log: log) : nil
        player.actionAtItemEnd = .advance
        let nc = NotificationCenter.default
        let name = kind.shortName
        observers.append(nc.addObserver(forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [log] note in
            let reason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String ?? "none"
            let rate = (note.object as? AVPlayer)?.rate ?? -1
            log.log(name, "rateDidChange rate \(rate) reason \(reason)")
        })
        observers.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [log] _ in
            log.log(name, "didPlayToEndTime")
        })
    }

    public func load(_ urls: [URL]) throws {
        self.urls = urls
        player.removeAllItems()
        for url in urls {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            if let tap, let track = asset.tracks(withMediaType: .audio).first, let mtTap = tap.makeTap() {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.audioTapProcessor = mtTap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                item.audioMix = mix
            }
            player.insert(item, after: nil)
        }
        log.log(kind.shortName, "load \(urls.count) item(s)")
    }

    public func play() {
        log.log(kind.shortName, "play")
        player.play()
    }

    public func pause() {
        log.log(kind.shortName, "pause")
        player.pause()
    }

    public func seek(by seconds: TimeInterval) {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        log.log(kind.shortName, "seek +\(seconds) to \(target.seconds)")
        player.seek(to: target)
    }

    public func next() {
        log.log(kind.shortName, "next")
        player.advanceToNextItem()
    }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    public var currentTime: TimeInterval { player.currentTime().seconds }
    public var rate: Float { player.rate }

    public var tapGain: Float {
        get { tap?.snapshot.gain ?? 1 }
        set {
            tap?.setGain(newValue)
            log.log(kind.shortName, "tap gain \(newValue) at engine time \(currentTime)")
        }
    }

    public var tapSnapshot: GainRMSTap.Snapshot? { tap?.snapshot }

    public var leadSeconds: TimeInterval? {
        guard let tap else { return nil }
        let snap = tap.snapshot
        guard snap.processCalls > 0 else { return nil }
        meter.record(lastEnqueued: snap.lastProcessedEnd, now: currentTime, at: .now)
        return meter.current
    }

    public var leadMeter: LeadMeter { meter }

    public func attach(to picker: AVRoutePickerView) {
        self.picker = picker
        picker.player = kind == .a ? player : nil
        log.log(kind.shortName, "attach picker.player \(kind == .a ? "set" : "nil")")
    }

    public func detach() {
        picker?.player = nil
        picker = nil
        log.log(kind.shortName, "detach")
    }

    public func probe() -> [ProbeLine] {
        var lines: [ProbeLine] = [
            ("items", "\(player.items().count)"),
            ("timeControlStatus", "\(player.timeControlStatus.rawValue)"),
            ("reasonForWaitingToPlay", player.reasonForWaitingToPlay?.rawValue ?? "none"),
            ("rate", "\(player.rate)"),
            ("itemStatus", "\(player.currentItem?.status.rawValue ?? -1)"),
            ("itemError", player.currentItem?.error?.localizedDescription ?? "none"),
            ("allowsExternalPlayback", "\(player.allowsExternalPlayback)"),
            ("isExternalPlaybackActive", "\(player.isExternalPlaybackActive)"),
        ]
        if let snap = tap?.snapshot {
            lines.append(("tap", "calls \(snap.processCalls) rms \(snap.rms) end \(snap.lastProcessedEnd) format \(snap.format)"))
        }
        return lines
    }

    public func teardown() {
        player.pause()
        player.removeAllItems()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        log.log(kind.shortName, "teardown")
    }
}
