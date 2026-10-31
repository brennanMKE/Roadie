import AppKit
import SkinKit
import VisualizationKit

@testable import Roadie

/// A renderer double that accepts only one kind of preset and records every call (#0257). The default is a MilkDrop
/// stand-in, so tests can list and load `.milk` presets without Metal.
@MainActor
final class StandInMilkRenderer: VisualizationRenderer {
    struct Failure: Error {}

    let view = NSView()
    let kindName: String
    let problems: [String] = []
    private let accepts: (VisualizationPreset) -> Bool
    var failing = false
    private(set) var loads: [String] = []
    private(set) var feeds = 0
    private(set) var draws = 0
    private(set) var resets = 0
    private(set) var reducedMotion: Bool?
    private(set) var colorSets = 0

    init(kindName: String = "milk", accepts: ((VisualizationPreset) -> Bool)? = nil) {
        self.kindName = kindName
        self.accepts = accepts ?? { if case .milk = $0.kind { true } else { false } }
    }

    /// A classic-only double.
    static func classic() -> StandInMilkRenderer {
        StandInMilkRenderer(kindName: "classic") { if case .classic = $0.kind { true } else { false } }
    }

    func canLoad(_ preset: VisualizationPreset) -> Bool { accepts(preset) }

    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws {
        if failing { throw Failure() }
        loads.append(preset.id)
    }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) { feeds += 1 }
    func draw(at time: TimeInterval) { draws += 1 }
    func setReducedMotion(_ on: Bool) { reducedMotion = on }
    func setColors(_ colors: [SkinKit.RGBColor]) { colorSets += 1 }
    func reset() { resets += 1 }
}
