import AppKit
import AudioCore
import MusicBackendKit
import SkinKit
import VisualizationKit
import XCTest

@testable import Roadie

/// The visualization window's model and the classic renderer (#0235), on an isolated test configuration.
@MainActor
final class VisualizationModelTests: PlayerModelTestCase {
    private func visModel(_ setUp: (UserDefaults) -> Void = { _ in }) throws -> PlayerModel {
        var configuration = try testConfiguration()
        configuration.visRenderer = "classic"
        configuration.visSeed = 1
        setUp(configuration.defaults)
        return makeModel(configuration)
    }

    func testOpeningTurnsTheStereoFeedOnAndClosingTurnsItOff() throws {
        let model = try visModel()
        let vis = model.visualization
        XCTAssertFalse(model.player.analyzer.isStereoEnabled)
        vis.open()
        vis.setVisible(true)
        XCTAssertTrue(vis.isRendering)
        XCTAssertTrue(model.player.analyzer.isStereoEnabled)
        vis.close()
        XCTAssertFalse(vis.isRendering)
        XCTAssertFalse(model.player.analyzer.isStereoEnabled)
    }

    func testOcclusionPausesRenderingAndTheStereoFeed() throws {
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        vis.setVisible(true)
        vis.setVisible(false)
        XCTAssertTrue(vis.isOpen)
        XCTAssertFalse(vis.isRendering)
        XCTAssertFalse(model.player.analyzer.isStereoEnabled)
        vis.setVisible(true)
        XCTAssertTrue(vis.isRendering)
        XCTAssertTrue(model.player.analyzer.isStereoEnabled)
    }

    func testOpensOnTheLastPresetShown() throws {
        let model = try visModel { $0.set("classic:mirror", forKey: VisualizationSettings.Key.lastPreset) }
        model.visualization.open()
        XCTAssertEqual(model.visualization.currentPreset?.name, "Classic Mirror")
        XCTAssertEqual(model.visualization.windowTitle, "Visualization — Classic Mirror")
    }

    func testUnknownLastPresetFallsBackToTheFirstClassic() throws {
        let model = try visModel { $0.set("user:gone.milk", forKey: VisualizationSettings.Key.lastPreset) }
        model.visualization.open()
        XCTAssertEqual(model.visualization.currentPreset?.id, "classic:spectrum")
    }

    func testLoadingAPresetRemembersIt() throws {
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        let loaded = vis.load(.classic(.stereoScope), transition: 0)
        XCTAssertTrue(loaded)
        XCTAssertEqual(vis.currentPreset?.id, "classic:stereoScope")
        XCTAssertEqual(model.defaults.string(forKey: VisualizationSettings.Key.lastPreset), "classic:stereoScope")
        XCTAssertEqual(VisualizationSettings.load(from: model.defaults).lastPreset, "classic:stereoScope")
    }

    func testAFailedLoadKeepsThePreviousPreset() throws {
        let model = try visModel()
        let vis = model.visualization
        let double = FailingRenderer(failing: "classic:mirror")
        vis.makeRenderer = { double }
        vis.open()
        XCTAssertEqual(vis.currentPreset?.id, "classic:spectrum")
        let loaded = vis.load(.classic(.mirror), transition: 0)
        XCTAssertFalse(loaded)
        XCTAssertEqual(vis.currentPreset?.id, "classic:spectrum")
        XCTAssertEqual(vis.navigator.current?.id, "classic:spectrum")
        XCTAssertFalse(vis.navigator.usable.contains { $0.id == "classic:mirror" })
        XCTAssertEqual(double.loads.last, "classic:mirror")
    }

    func testAudioSourceIsRemoteForASpeakerAndLocalForThisMac() {
        let mac = OutputDevice.thisMacID
        let speaker = OutputDevice.ID(rawValue: "speaker-1")
        XCTAssertEqual(
            VisualizationModel.audioSource(selectedOutput: mac, thisMacID: mac, outputName: nil, state: .playing), .local)
        XCTAssertEqual(
            VisualizationModel.audioSource(selectedOutput: speaker, thisMacID: mac, outputName: "Kitchen", state: .playing),
            .remote("Kitchen"))
        XCTAssertEqual(
            VisualizationModel.audioSource(selectedOutput: mac, thisMacID: mac, outputName: nil, state: .stopped), VisualizationModel.AudioSource.none)
        XCTAssertEqual(
            VisualizationModel.audioSource(selectedOutput: speaker, thisMacID: mac, outputName: nil, state: .stopped), VisualizationModel.AudioSource.none)
    }

    func testOpenStatePersists() throws {
        let model = try visModel()
        let vis = model.visualization
        vis.open()
        XCTAssertTrue(model.defaults.bool(forKey: VisualizationSettings.Key.windowOpen))
        vis.close()
        XCTAssertFalse(model.defaults.bool(forKey: VisualizationSettings.Key.windowOpen))
    }

    func testClassicSpectrumRespondsToAudio() {
        let renderer = ClassicVisualizer(colors: VisRenderer.defaultColors)
        let rate = 44_100.0
        let frames = 1_024
        var samples = [Float](repeating: 0, count: 2 * frames)
        for i in 0..<frames {
            let s = Float(0.8 * sin(2 * Double.pi * 1_000 * Double(i) / rate))
            samples[2 * i] = s
            samples[2 * i + 1] = s
        }
        var time = 0.0
        for _ in 0..<10 {
            samples.withUnsafeBufferPointer { renderer.feed($0, channels: 2, sampleRate: rate) }
            time += 1.0 / 60
            renderer.draw(at: time)
        }
        let heights = renderer.barHeights
        let peak = heights.max() ?? 0
        XCTAssertGreaterThan(peak, 0, "\(heights)")
        let map = SpectrumColumnMap(fftSize: ClassicVisualizer.fftSize, sampleRate: rate)
        let column = (0..<VisBars.columnCount).first { map.frequencyRange(ofColumn: $0).contains(1_000) } ?? -1
        let loudest = heights.firstIndex(of: peak) ?? -100
        XCTAssertLessThanOrEqual(abs(loudest - column), 4, "loudest \(loudest), 1 kHz column \(column): \(heights)")

        for _ in 0..<30 {
            time += 1.0 / 60
            renderer.draw(at: time)
        }
        XCTAssertEqual(renderer.barHeights.max(), 0, "\(renderer.barHeights)")
    }

    func testRendererFactoryPicksClassicByDefault() {
        var configuration = RoadieConfiguration()
        XCTAssertEqual(
            VisualizationRendererFactory.make(configuration: configuration, colors: VisRenderer.defaultColors).kindName,
            "classic")
        configuration.visRenderer = "nonsense"
        XCTAssertEqual(
            VisualizationRendererFactory.make(configuration: configuration, colors: VisRenderer.defaultColors).kindName,
            "classic")
    }
}

/// A renderer that throws for one preset id and records every load.
@MainActor
private final class FailingRenderer: VisualizationRenderer {
    struct Failure: Error {}

    let failing: String
    private(set) var loads: [String] = []
    let view = NSView()
    let kindName = "double"
    let problems: [String] = []

    init(failing: String) { self.failing = failing }

    func canLoad(_ preset: VisualizationPreset) -> Bool { true }

    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws {
        loads.append(preset.id)
        if preset.id == failing { throw Failure() }
    }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {}
    func draw(at time: TimeInterval) {}
    func setReducedMotion(_ on: Bool) {}
    func setColors(_ colors: [SkinKit.RGBColor]) {}
}
