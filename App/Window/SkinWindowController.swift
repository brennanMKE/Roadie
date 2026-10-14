import AppKit
import Observation
import SkinKit
import SwiftUI

@MainActor
final class SkinWindowController: NSObject, NSWindowDelegate, TitleBarDragging {
    enum Mode {
        case normal, shade

        var skinSize: CGSize {
            switch self {
            case .normal: MainWindowLayout.size
            case .shade: MainWindowLayout.shadeSize
            }
        }
    }

    /// Title-bar buttons in skin pixels (Webamp css/main-window.css): 9x9 at y 3.
    static let titleBarHeight: CGFloat = MainWindowLayout.titleBar.height
    static let buttonRects: [CGRect] = MainWindowLayout.TitleButton.allCases.map { MainWindowLayout.rect($0) }

    let window: SkinWindow
    var mode: Mode = .normal { didSet { applyLayout() } }

    private let model: PlayerModel
    private let shape: SkinShapeView
    private let hosting: NSHostingView<AnyView>
    private let dragView = TitleBarDragView()
    private var hasBeenShown = false

    init(model: PlayerModel) {
        self.model = model
        let size = Mode.normal.skinSize
        window = SkinWindow(contentSize: CGSize(width: size.width * model.scale, height: size.height * model.scale))
        shape = SkinShapeView(frame: NSRect(origin: .zero, size: window.frame.size))
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        hosting.rootView = AnyView(PlayerView().environment(model).environment(\.skinWindow, self))
        hosting.sizingOptions = []
        shape.addSubview(hosting)
        dragView.delegate = self
        shape.addSubview(dragView)
        window.contentView = shape
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        applyLayout()
        observe()
    }

    func show() {
        if !hasBeenShown {
            hasBeenShown = true
            if !window.setFrameUsingName("MainWindow") { window.center() }
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.performClose(nil) }
    func minimize() { window.miniaturize(nil) }

    /// `withObservationTracking` fires once per change, so it re-registers itself.
    private func observe() {
        withObservationTracking {
            _ = model.skin
            _ = model.scale
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyLayout()
                self?.observe()
            }
        }
    }

    private func applyLayout() {
        let scale = model.scale
        let skinSize = mode.skinSize
        let pixelSize = CGSize(width: skinSize.width * scale, height: skinSize.height * scale)
        // Keep the top-left corner where it is when the height changes.
        let oldFrame = window.frame
        window.setContentSize(pixelSize)
        window.setFrameTopLeftPoint(NSPoint(x: oldFrame.minX, y: oldFrame.maxY))
        shape.frame = NSRect(origin: .zero, size: pixelSize)

        let region = model.skin?.region
        let polygons = mode == .normal ? region?.normal : region?.windowShade
        shape.apply(
            path: polygons.map { SkinRegion.path($0, scale: scale) },
            mask: polygons.flatMap { SkinRegion.maskImage($0, size: skinSize, scale: scale) })

        hosting.frame = shape.bounds
        let barHeight = Self.titleBarHeight * scale
        dragView.frame = NSRect(x: 0, y: pixelSize.height - barHeight, width: pixelSize.width, height: barHeight)
        dragView.excludedRects = Self.buttonRects.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        window.invalidateShadow()
    }

    // MARK: TitleBarDragging

    func dragBegan() {}
    func drag(to proposedOrigin: NSPoint) { window.setFrameOrigin(proposedOrigin) }
    func dragEnded() {}
    func titleBarDoubleClicked() {}

    // MARK: NSWindowDelegate

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyLayout()
    }
}
