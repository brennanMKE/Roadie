import AppKit
import Metal
import MilkMetal
import QuartzCore
import SkinKit
import VisualizationKit
import os

enum MilkVisualizerError: Error, Equatable {
    /// The preset has no file to read (not a `.milk` preset).
    case noFile
}

/// Draws `.milk` presets with MilkDropMetalKit's `MilkRenderer` (#0243, design docs/design/visualization.md §3.2).
/// Roadie owns the render loop: `VisualizationModel.tick` feeds once per tick on the main actor (MilkMetal's
/// single-producer rule) and then calls `draw(at:)`. The renderer paces the audio itself (api-1.0.md F5).
@MainActor
final class MilkVisualizer: VisualizationRenderer {
    private static let log = Logger(subsystem: "co.sstools.roadie", category: "Visualization")

    let renderer: MilkRenderer
    private let commandQueue: MTLCommandQueue
    private let metalView: MetalVisualizationView

    var view: NSView { metalView }
    var kindName: String { "milk" }
    var problems: [String] { renderer.presetErrors }
    /// Frames committed by `draw(at:)`, for tests (a draw that returns early doesn't count).
    private(set) var framesDrawn = 0

    init(device: MTLDevice) throws(MilkRendererError) {
        // Not _srgb: MilkDrop's output is display-referred (api-1.0.md F11).
        renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
        guard let queue = device.makeCommandQueue() else { throw MilkRendererError.noCommandQueue }
        commandQueue = queue
        metalView = MetalVisualizationView(device: device, pixelFormat: .bgra8Unorm)
    }

    /// The system default device, or nil (logged) when there's none or the renderer can't be built.
    static func make() -> MilkVisualizer? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("no Metal device; MilkDrop presets can't be drawn")
            return nil
        }
        do {
            return try MilkVisualizer(device: device)
        } catch {
            log.error("MilkRenderer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func canLoad(_ preset: VisualizationPreset) -> Bool {
        if case .milk = preset.kind { return true }
        return false
    }

    func load(_ preset: VisualizationPreset, transition: TimeInterval) throws {
        guard let url = preset.url else { throw MilkVisualizerError.noFile }
        let milk = try MilkPreset(contentsOf: url)
        try renderer.load(milk, transition: transition)
        let errors = renderer.presetErrors
        if let first = errors.first {
            Self.log.notice("\(preset.name, privacy: .public): \(errors.count) preset problem(s), first: \(first, privacy: .public)")
        }
    }

    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        renderer.feed(samples: samples, channels: channels, sampleRate: sampleRate)
    }

    func draw(at time: TimeInterval) {
        guard let layer = metalView.metalLayer, layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        renderer.render(to: drawable.texture, commandBuffer: commandBuffer, time: time)
        commandBuffer.present(drawable)
        // Every buffer must be committed: the renderer holds three frames in flight on a semaphore (api-1.0.md F3).
        commandBuffer.commit()
        framesDrawn += 1
    }

    func setReducedMotion(_ on: Bool) {
        renderer.transitionPattern = on ? .crossfade : .random
    }

    /// MilkDrop presets carry their own colours.
    func setColors(_ colors: [SkinKit.RGBColor]) {}

    /// Drops queued audio and restarts the renderer's clock (#0257: when MilkDrop becomes the active kind again).
    func reset() {
        renderer.reset()
    }
}

/// An `NSView` backed by a `CAMetalLayer`, with no display link of its own: `VisualizationModel.tick` drives it.
/// Modelled on MilkMetal's `MilkView`.
@MainActor
final class MetalVisualizationView: NSView {
    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, frame: NSRect = .zero) {
        self.device = device
        self.pixelFormat = pixelFormat
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }
}
