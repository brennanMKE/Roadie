import AppKit
import Metal
import MilkMetal
import QuartzCore
import VisualizationKit
import XCTest

@testable import Roadie

/// MilkDropMetalKit's renderer behind Roadie's renderer seam (#0243). Presets are written to a temp directory.
@MainActor
final class MilkVisualizerTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MilkVisualizerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private static let goodPreset = """
        [preset00]
        fRating=3.000000
        zoom=1.010000
        rot=0.000000
        nWaveMode=0
        per_frame_1=wave_r = 0.5 + 0.5*sin(time);
        """

    private func makeVisualizer() throws -> MilkVisualizer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let vis = try MilkVisualizer(device: device)
        vis.renderer.compilesShadersInBackground = false
        return vis
    }

    private func writePreset(_ name: String, _ text: String) throws -> VisualizationPreset {
        let url = directory.appendingPathComponent("\(name).milk")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .milk(url: url, relativePath: "\(name).milk", source: .user)
    }

    func testCreatesARendererOnTheSystemDevice() throws {
        let vis = try makeVisualizer()
        XCTAssertEqual(vis.kindName, "milk")
        let layer = try XCTUnwrap(vis.view.layer as? CAMetalLayer)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(vis.renderer.pixelFormat, .bgra8Unorm)
    }

    func testCanLoadOnlyMilkPresets() throws {
        let vis = try makeVisualizer()
        XCTAssertTrue(vis.canLoad(try writePreset("Good", Self.goodPreset)))
        for style in ClassicStyle.allCases {
            XCTAssertFalse(vis.canLoad(.classic(style)), style.rawValue)
        }
    }

    func testLoadingAMilkPresetSucceeds() throws {
        let vis = try makeVisualizer()
        try vis.load(try writePreset("Good One", Self.goodPreset), transition: 0)
        XCTAssertEqual(vis.renderer.preset?.name, "Good One")
        XCTAssertEqual(vis.problems, [])
    }

    func testAnEmptyPresetThrows() throws {
        let vis = try makeVisualizer()
        try vis.load(try writePreset("Good", Self.goodPreset), transition: 0)
        let empty = try writePreset("Empty", "just some words\nwith no settings\n")
        XCTAssertThrowsError(try vis.load(empty, transition: 0)) { error in
            guard case .empty? = error as? MilkPresetError else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
        XCTAssertEqual(vis.renderer.preset?.name, "Good")
    }

    func testAMissingFileThrows() throws {
        let vis = try makeVisualizer()
        let url = directory.appendingPathComponent("Missing.milk")
        let preset = VisualizationPreset.milk(url: url, relativePath: "Missing.milk", source: .user)
        XCTAssertThrowsError(try vis.load(preset, transition: 0)) { error in
            guard case .unreadableFile? = error as? MilkPresetError else {
                return XCTFail("expected .unreadableFile, got \(error)")
            }
        }
    }

    func testABrokenEquationIsReportedNotThrown() throws {
        let vis = try makeVisualizer()
        let broken = try writePreset("Broken", """
            [preset00]
            zoom=1.010000
            per_frame_1=zoom = ((( * ;
            """)
        XCTAssertNoThrow(try vis.load(broken, transition: 0))
        XCTAssertEqual(vis.renderer.preset?.name, "Broken")
        XCTAssertFalse(vis.problems.isEmpty)
    }

    func testDrawCommitsEveryCommandBuffer() throws {
        let vis = try makeVisualizer()
        try vis.load(try writePreset("Good", Self.goodPreset), transition: 0)
        vis.view.setFrameSize(NSSize(width: 64, height: 64))
        let layer = try XCTUnwrap(vis.view.layer as? CAMetalLayer)
        layer.drawableSize = CGSize(width: 64, height: 64)
        for frame in 0..<10 {
            vis.draw(at: Double(frame) / 60)
        }
        XCTAssertEqual(vis.framesDrawn, 10, "draw returned early instead of committing a frame")
        let queue = try XCTUnwrap(vis.renderer.device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let done = expectation(description: "command buffer completed")
        buffer.addCompletedHandler { _ in done.fulfill() }
        buffer.commit()
        wait(for: [done], timeout: 2)
    }

    func testFeedThenDrawKeepsThePreset() throws {
        let vis = try makeVisualizer()
        try vis.load(try writePreset("Good", Self.goodPreset), transition: 0)
        vis.view.setFrameSize(NSSize(width: 64, height: 64))
        let rate = 48_000.0
        let frames = 800
        var phase = 0.0
        for tick in 0..<30 {
            var chunk = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let value = Float(sin(phase) * 0.5)
                chunk[2 * i] = value
                chunk[2 * i + 1] = value
                phase += 2 * Double.pi * 1_000 / rate
            }
            chunk.withUnsafeBufferPointer { vis.feed($0, channels: 2, sampleRate: rate) }
            vis.draw(at: Double(tick) / 60)
        }
        XCTAssertEqual(vis.renderer.preset?.name, "Good")
    }

    func testReducedMotionMakesTransitionsCrossfades() throws {
        let vis = try makeVisualizer()
        vis.setReducedMotion(true)
        XCTAssertEqual(vis.renderer.transitionPattern, .crossfade)
        vis.setReducedMotion(false)
        XCTAssertEqual(vis.renderer.transitionPattern, .random)
    }
}
