@preconcurrency import AVFoundation
import AVKit
import Foundation

public enum EngineKind: String, CaseIterable, Sendable {
    case a, aPrime, aTap, b, bDevice

    public var title: String {
        switch self {
        case .a: "A: AVQueuePlayer, picker.player set"
        case .aPrime: "A\u{2032}: picker.player nil"
        case .aTap: "A+tap"
        case .b: "B: renderer+synchronizer, picker nil"
        case .bDevice: "B-dev: renderer to CoreAudio AirPlay device"
        }
    }

    /// Short name used in log lines.
    public var shortName: String {
        switch self {
        case .a: "A"
        case .aPrime: "A'"
        case .aTap: "A+tap"
        case .b: "B"
        case .bDevice: "B-dev"
        }
    }
}

public typealias ProbeLine = (String, String)

/// One playback stack under test. Constructing an engine never starts I/O; only `play()` does.
@MainActor
public protocol SpikeEngine: AnyObject {
    var kind: EngineKind { get }
    func load(_ urls: [URL]) throws
    func play()
    func pause()
    func seek(by seconds: TimeInterval)
    func next()
    var volume: Float { get set }
    var currentTime: TimeInterval { get }
    var rate: Float { get }
    /// Requested-ahead seconds (see `LeadMeter`); nil when the engine has no such measurement.
    var leadSeconds: TimeInterval? { get }
    /// A and A+tap set `picker.player`; A', B and B-dev set it to nil.
    func attach(to picker: AVRoutePickerView)
    func detach()
    func probe() -> [ProbeLine]
    /// Rate 0, stop requesting data, flush, drop items.
    func teardown()
}

@MainActor
public enum EngineFactory {
    public static func make(_ kind: EngineKind, log: SpikeLog, deviceUID: String? = nil) -> any SpikeEngine {
        switch kind {
        case .a, .aPrime, .aTap: QueuePlayerEngine(kind: kind, log: log)
        case .b, .bDevice: SampleBufferEngine(kind: kind, log: log, deviceUID: deviceUID)
        }
    }
}
