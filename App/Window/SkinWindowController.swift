import AppKit
import Observation
import SkinKit
import SwiftUI

/// Which skinned window a controller hosts. Supplies everything that differs between the windows: the skin-pixel
/// size per mode, the `region.txt` section that shapes it, the frame-autosave name and the title bar's drag holes.
/// #0029 adds `.playlist` here (and a size parameter, since that window resizes); nothing else in the controller
/// names a window.
enum SkinWindowKind {
    case main, equalizer

    /// The window's size in skin pixels.
    func skinSize(_ mode: SkinWindowController.Mode) -> CGSize {
        switch (self, mode) {
        case (.main, .normal): MainWindowLayout.size
        case (.main, .shade): MainWindowLayout.shadeSize
        case (.equalizer, .normal): EQLayout.windowSize
        case (.equalizer, .shade): EQLayout.shadeSize
        }
    }

    var autosaveName: String {
        switch self {
        case .main: "MainWindow"
        case .equalizer: "EqualizerWindow"
        }
    }

    /// The `region.txt` polygons that shape the window in `mode`; nil = rectangular.
    func polygons(_ region: SkinRegion?, _ mode: SkinWindowController.Mode) -> [SkinRegion.Polygon]? {
        switch (self, mode) {
        case (.main, .normal): region?.normal
        case (.main, .shade): region?.windowShade
        case (.equalizer, .normal): region?.equalizer
        case (.equalizer, .shade): region?.equalizerShade
        }
    }

    var titleBarHeight: CGFloat {
        switch self {
        case .main: MainWindowLayout.titleBar.height
        case .equalizer: EQLayout.titleBarHeight
        }
    }

    /// Title-bar buttons in skin pixels; a drag started on one belongs to the button, not the window.
    var titleButtonRects: [CGRect] {
        switch self {
        case .main: MainWindowLayout.TitleButton.allCases.map { MainWindowLayout.rect($0) }
        case .equalizer: EQLayout.titleButtonRects
        }
    }
}

/// Hosts one skinned window: a borderless `SkinWindow` whose content is a SwiftUI view in skin pixels, masked to the
/// skin's region and dragged by its title bar. One controller per window; `kind` says which.
@MainActor
final class SkinWindowController: NSObject, NSWindowDelegate, TitleBarDragging {
    enum Mode { case normal, shade }

    let kind: SkinWindowKind
    let window: SkinWindow
    var mode: Mode = .normal { didSet { applyLayout() } }
    /// Called from `windowWillClose`; a window the model tracks tells it that the window is no longer open.
    var onClose: (() -> Void)?

    private let model: PlayerModel
    private let shape: SkinShapeView
    private let hosting: NSHostingView<AnyView>
    private let dragView = TitleBarDragView()
    private var hasBeenShown = false

    /// `rootView` is drawn in skin pixels scaled by the view itself; the controller adds the model and itself to its
    /// environment.
    init(kind: SkinWindowKind, model: PlayerModel, rootView: some View) {
        self.kind = kind
        self.model = model
        let size = kind.skinSize(.normal)
        window = SkinWindow(contentSize: CGSize(width: size.width * model.scale, height: size.height * model.scale))
        shape = SkinShapeView(frame: NSRect(origin: .zero, size: window.frame.size))
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        hosting.rootView = AnyView(rootView.environment(model).environment(\.skinWindow, self))
        hosting.sizingOptions = []
        shape.addSubview(hosting)
        dragView.delegate = self
        shape.addSubview(dragView)
        window.contentView = shape
        window.delegate = self
        window.setFrameAutosaveName(kind.autosaveName)
        applyLayout()
        observe()
    }

    /// Brings the window forward. The first time, it goes where it was last (the autosaved frame); with none saved it
    /// sits directly under `reference` (Webamp's default layout), or centres when there is no reference.
    func show(below reference: NSWindow? = nil) {
        if !hasBeenShown {
            hasBeenShown = true
            if !window.setFrameUsingName(kind.autosaveName) {
                if let reference {
                    window.setFrameTopLeftPoint(NSPoint(x: reference.frame.minX, y: reference.frame.minY))
                } else {
                    window.center()
                }
            }
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Hides without tearing the window down (`performClose` hides; `show` brings the same window back).
    func hide() { window.orderOut(nil) }

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
        let skinSize = kind.skinSize(mode)
        let pixelSize = CGSize(width: skinSize.width * scale, height: skinSize.height * scale)
        // Keep the top-left corner where it is when the height changes.
        let oldFrame = window.frame
        window.setContentSize(pixelSize)
        window.setFrameTopLeftPoint(NSPoint(x: oldFrame.minX, y: oldFrame.maxY))
        shape.frame = NSRect(origin: .zero, size: pixelSize)

        let region = model.skin?.region
        let polygons = kind.polygons(region, mode)
        shape.apply(
            path: polygons.map { SkinRegion.path($0, scale: scale) },
            mask: polygons.flatMap { SkinRegion.maskImage($0, size: skinSize, scale: scale) })

        hosting.frame = shape.bounds
        let barHeight = kind.titleBarHeight * scale
        dragView.frame = NSRect(x: 0, y: pixelSize.height - barHeight, width: pixelSize.width, height: barHeight)
        dragView.excludedRects = kind.titleButtonRects.map {
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

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
