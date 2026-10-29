import AppKit
import SkinKit
import VisualizationKit
import os

/// What draws the visualization window (design docs/design/visualization.md §3.2). #0235: `ClassicVisualizer` (Core
/// Graphics). #0243: `MilkVisualizer` (MilkMetal). Roadie owns the render loop: `VisualizationModel.tick` feeds, then
/// draws, once per display-link tick.
@MainActor
protocol VisualizationRenderer: AnyObject {
    var view: NSView { get }
    /// "classic" | "milk", for the probe and logs.
    var kindName: String { get }
    func canLoad(_ preset: VisualizationPreset) -> Bool
    /// Shows `preset`, blended over `transition` seconds (0 cuts). Throws when the preset can't be read or drawn.
    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws
    /// Audio since the previous tick: interleaved Float32, `channels` 2. Called on the main actor, once per tick.
    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double)
    /// Draws one frame. `time` rises steadily from 0 while the window renders (paused time excluded).
    func draw(at time: TimeInterval)
    /// Crossfade-only transitions.
    func setReducedMotion(_ on: Bool)
    /// The skin's `viscolor.txt` colours (24 entries).
    func setColors(_ colors: [SkinKit.RGBColor])
    /// The last load's warnings.
    var problems: [String] { get }
}

@MainActor
enum VisualizationRendererFactory {
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "Visualization")

    /// Debug `-RoadieVisRenderer classic|milk` wins (an unknown value logs and uses classic); otherwise classic until
    /// #0243 adds the MilkMetal branch. `milk` also falls back to classic until then.
    static func make(configuration: RoadieConfiguration, colors: [SkinKit.RGBColor]) -> any VisualizationRenderer {
        switch configuration.visRenderer {
        case nil, "classic"?:
            break
        case "milk"?:
            log.notice("MilkMetal isn't linked yet (#0243); using the classic visualizer")
        case let other?:
            log.error("unknown -RoadieVisRenderer \(other, privacy: .public); using the classic visualizer")
        }
        return ClassicVisualizer(colors: colors)
    }
}
