import AppKit
import Metal
import MilkMetal
import SkinKit
import VisualizationKit
import XCTest

@testable import Roadie

/// The MilkDrop presets Roadie bundles from MilkDropMetalKit (#0258), and how the window lists and starts on them.
@MainActor
final class BundledPresetTests: PlayerModelTestCase {
    private static let classicNames = PresetCatalog.classics.map(\.name)
    /// The player models behind `visModel`, kept alive for the test.
    private var models: [PlayerModel] = []

    private func appPresetsFolder() throws -> URL {
        try XCTUnwrap(RoadieConfiguration.appPresetsFolder, "no app resources folder")
    }

    /// A model whose renderer is `renderer`, with `bundled` as its bundled presets folder and empty defaults.
    private func visModel(
        bundled: URL?, renderer: @escaping @MainActor () -> any VisualizationRenderer
    ) throws -> VisualizationModel {
        var configuration = try testConfiguration()
        configuration.visSeed = 1
        configuration.defaults.set("sequential", forKey: VisualizationSettings.Key.order)
        let model = makeModel(configuration)
        models.append(model)
        let vis = model.visualization
        vis.bundledPresetsFolder = bundled
        vis.makeRenderer = renderer
        return vis
    }

    private static func milkCapable() -> any VisualizationRenderer {
        MixedVisualizer(classic: ClassicVisualizer(colors: VisRenderer.defaultColors), milk: StandInMilkRenderer())
    }

    private static func classicOnly() -> any VisualizationRenderer {
        MixedVisualizer(classic: ClassicVisualizer(colors: VisRenderer.defaultColors), milk: nil)
    }

    func testTheAppBundlesTheGalleryPresets() throws {
        let folder = try appPresetsFolder()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".milk") }.count, 42, "files: \(files.sorted())")
        XCTAssertTrue(files.contains("gallery.json"), "no gallery.json: \(files.sorted())")
        let presets = PresetCatalog.bundled(in: folder)
        XCTAssertEqual(presets.count, 42)
        XCTAssertTrue(presets.allSatisfy { $0.source == .bundled && $0.id.hasPrefix("bundled:") })
        XCTAssertTrue(presets.allSatisfy { !$0.name.hasSuffix(".milk") && $0.name != $0.url?.deletingPathExtension().lastPathComponent },
                      "untitled: \(presets.filter { $0.name == $0.url?.deletingPathExtension().lastPathComponent }.map(\.id))")
        XCTAssertTrue(presets.contains { $0.id == VisualizationModel.freshInstallPreset && $0.name == "Spike Tunnel" })
    }

    func testEveryBundledPresetLoadsCleanly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let presets = PresetCatalog.bundled(in: try appPresetsFolder())
        XCTAssertEqual(presets.count, 42)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var offenders: [String] = []
        for preset in presets {
            let vis = try MilkVisualizer(device: device)
            vis.renderer.compilesShadersInBackground = false
            do {
                try vis.load(preset, transition: 0)
            } catch {
                offenders.append("\(preset.id): \(error)")
                continue
            }
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            vis.renderer.render(to: texture, commandBuffer: commandBuffer, time: 1)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.status != .completed { offenders.append("\(preset.id): command buffer \(commandBuffer.status)") }
            if !vis.problems.isEmpty { offenders.append("\(preset.id): \(vis.problems)") }
        }
        XCTAssertEqual(offenders, [], "presets with problems")
    }

    func testAFreshInstallStartsOnSpikeTunnel() throws {
        let vis = try visModel(bundled: try appPresetsFolder(), renderer: Self.milkCapable)
        vis.open()
        XCTAssertEqual(vis.currentPreset?.id, "bundled:spike-tunnel.milk")
        XCTAssertEqual(vis.currentPreset?.name, "Spike Tunnel")
    }

    func testAFreshInstallWithoutMilkStartsOnTheFirstClassic() throws {
        let vis = try visModel(bundled: try appPresetsFolder(), renderer: Self.classicOnly)
        vis.open()
        XCTAssertEqual(vis.currentPreset?.id, PresetCatalog.classics.first?.id)
        XCTAssertEqual(vis.navigator.presets.map(\.name), Self.classicNames)
    }

    func testBundledPresetsAreListedAfterTheClassics() async throws {
        let bundled = try temporaryDirectory("roadie-bundled")
        for name in ["zoom.milk", "spike-tunnel.milk"] { try Data("[preset00]\n".utf8).write(to: bundled.appending(path: name)) }
        try Data(#"{"categories":[{"name":"S","presets":[{"file":"spike-tunnel.milk","title":"Spike Tunnel"}]}]}"#.utf8)
            .write(to: bundled.appending(path: "gallery.json"))
        let user = try temporaryDirectory("roadie-user-presets")
        try Data("[preset00]\n".utf8).write(to: user.appending(path: "Alpha.milk"))
        let vis = try visModel(bundled: bundled, renderer: Self.milkCapable)
        vis.open()
        vis.updateSettings { $0.presetsFolder = user.path }
        await vis.reloadCatalogue().value
        XCTAssertEqual(vis.navigator.presets.map(\.name), Self.classicNames + ["Alpha", "Spike Tunnel", "zoom"])
        XCTAssertEqual(vis.navigator.presets.map(\.id).suffix(3), ["user:Alpha.milk", "bundled:spike-tunnel.milk", "bundled:zoom.milk"])
    }

    func testPresetsFolderRowShowsWhenMilkCanDraw() throws {
        let vis = try visModel(bundled: nil, renderer: Self.milkCapable)
        vis.canDrawMilkBeforeOpen = { true }
        XCTAssertTrue(vis.showsPresetsFolder, "before open, from the factory's answer")
        vis.open()
        XCTAssertTrue(vis.showsPresetsFolder)
    }

    func testPresetsFolderRowHiddenWithoutMilk() throws {
        let vis = try visModel(bundled: nil, renderer: Self.classicOnly)
        vis.canDrawMilkBeforeOpen = { false }
        XCTAssertFalse(vis.showsPresetsFolder, "before open, from the factory's answer")
        vis.open()
        XCTAssertFalse(vis.showsPresetsFolder)
    }
}
