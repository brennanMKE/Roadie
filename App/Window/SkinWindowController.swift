import AppKit
import Observation
import SkinKit
import SwiftUI
import WindowDocking

/// Which skinned window a controller hosts. Supplies everything that differs between the windows: the skin-pixel
/// size per mode, the `region.txt` section that shapes it, the legacy frame-autosave name and the title bar's drag holes.
/// Nothing else in the controller names a window, except that the playlist adds its AppKit input views.
enum SkinWindowKind {
    /// `playlist` carries the resize steps; the controller refreshes them from `PlaylistModel` as the user resizes.
    case main, equalizer, playlist(PlaylistLayout.Steps)

    /// The window's size in skin pixels.
    func skinSize(_ mode: SkinWindowController.Mode) -> CGSize {
        switch (self, mode) {
        case (.main, .normal): MainWindowLayout.size
        case (.main, .shade): MainWindowLayout.shadeSize
        case (.equalizer, .normal): EQLayout.windowSize
        case (.equalizer, .shade): EQLayout.shadeSize
        case (.playlist(let steps), .normal): PlaylistLayout(steps: steps).size
        case (.playlist(let steps), .shade):
            CGSize(width: PlaylistLayout(steps: steps).size.width, height: PlaylistLayout.shadeHeight)
        }
    }

    /// Which window the docking engine knows this as.
    var windowKind: WindowKind {
        switch self {
        case .main: .main
        case .equalizer: .equalizer
        case .playlist: .playlist
        }
    }

    /// The frame-autosave name an earlier build used; the docking coordinator reads it once to seed positions.
    var legacyAutosaveName: String {
        switch self {
        case .main: "MainWindow"
        case .equalizer: "EqualizerWindow"
        case .playlist: "PlaylistWindow"
        }
    }

    /// The `region.txt` polygons that shape the window in `mode`; nil = rectangular.
    func polygons(_ region: SkinRegion?, _ mode: SkinWindowController.Mode) -> [SkinRegion.Polygon]? {
        switch (self, mode) {
        case (.main, .normal): region?.normal
        case (.main, .shade): region?.windowShade
        case (.equalizer, .normal): region?.equalizer
        case (.equalizer, .shade): region?.equalizerShade
        case (.playlist, _): nil   // the playlist has no region
        }
    }

    var titleBarHeight: CGFloat {
        switch self {
        case .main: MainWindowLayout.titleBar.height
        case .equalizer: EQLayout.titleBarHeight
        case .playlist: PlaylistLayout.titleBarHeight
        }
    }

    /// Controls on the draggable strip, in skin pixels; a drag started on one belongs to the control, not the window.
    /// Normal mode: the title-bar buttons. Shade: the whole strip is the drag area, minus its buttons and displays.
    func dragExclusions(_ mode: SkinWindowController.Mode) -> [CGRect] {
        switch (self, mode) {
        case (.main, .normal): MainWindowLayout.TitleButton.allCases.map { MainWindowLayout.rect($0) }
        case (.main, .shade): MainShadeLayout.dragExclusions
        case (.equalizer, .normal): EQLayout.titleButtonRects
        case (.equalizer, .shade):
            EQLayout.titleButtonRects + [MainSliders.eqShadeVolume, MainSliders.eqShadeBalance].map {
                CGRect(origin: $0.origin, size: $0.size)
            }
        case (.playlist(let steps), .normal): PlaylistLayout(steps: steps).titleButtonRects
        case (.playlist(let steps), .shade):
            PlaylistShadeLayout.dragExclusions(width: PlaylistLayout(steps: steps).size.width)
        }
    }
}

/// Hosts one skinned window: a borderless `SkinWindow` whose content is a SwiftUI view in skin pixels, masked to the
/// skin's region and dragged by its title bar. One controller per window; `kind` says which.
@MainActor
final class SkinWindowController: NSObject, NSWindowDelegate, TitleBarDragging {
    enum Mode { case normal, shade }

    private(set) var kind: SkinWindowKind
    let window: SkinWindow
    /// Follows the model's shade flag for this window; set only by `applyLayout()`.
    private(set) var mode: Mode = .normal
    /// Set by `WindowDockingCoordinator.register`; drags and size changes go through it. nil in previews and offscreen
    /// renders, where the window just moves and resizes on its own.
    weak var coordinator: WindowDockingCoordinator?
    /// Whether the window has a position (restored, or set by its first `show`).
    var isPositioned = false
    /// The scale `applyLayout` last laid out at; a change in it (or in shade mode) keeps docked neighbours docked.
    private var layoutScale: CGFloat = 0
    /// Called from `windowWillClose`; a window the model tracks tells it that the window is no longer open.
    var onClose: (() -> Void)?

    private let model: PlayerModel
    private let shape: SkinShapeView
    private let hosting: NSHostingView<AnyView>
    private let dragView = TitleBarDragView()
    private var hasBeenShown = false
    /// The playlist's track-list and resize-corner input views; nil for the other windows.
    private var playlistOverlays: PlaylistWindowOverlays?

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
        if case .playlist = kind {
            let overlays = PlaylistWindowOverlays(model: model)
            overlays.install(in: shape)
            playlistOverlays = overlays
        }
        dragView.delegate = self
        shape.addSubview(dragView)
        window.contentView = shape
        window.delegate = self
        applyLayout()
        observe()
    }

    /// Brings the window forward. The first time, a window with no restored position sits directly under `reference`
    /// (Webamp's default layout), or centres when there is no reference.
    func show(below reference: NSWindow? = nil) {
        if !hasBeenShown {
            hasBeenShown = true
            if !isPositioned {
                if let reference {
                    window.setFrameTopLeftPoint(NSPoint(x: reference.frame.minX, y: reference.frame.minY))
                } else {
                    window.center()
                }
                isPositioned = true
                coordinator?.layoutDidChange()
            }
            applyLayout()
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
            _ = shadeWanted
            if case .playlist = kind { _ = model.playlist.steps }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyLayout()
                self?.observe()
            }
        }
    }

    /// Whether the model wants this window collapsed to its shade strip.
    private var shadeWanted: Bool {
        switch kind {
        case .main: model.isMainWindowShaded
        case .equalizer: model.isEQWindowShaded
        case .playlist: model.isPlaylistWindowShaded
        }
    }

    /// The one place a window changes size (scale, skin, shade, playlist steps), keeping the top-left corner. A scale or
    /// shade change goes through the coordinator, which moves the windows docked below or beside this one by the size
    /// difference; a playlist resize does not push its neighbours (as in Webamp).
    func applyLayout() {
        let wantedMode: Mode = shadeWanted ? .shade : .normal
        if let coordinator, window.isVisible, layoutScale != 0, model.scale != layoutScale || wantedMode != mode {
            coordinator.resize(self) { performLayout() }
        } else {
            performLayout()
        }
    }

    private func performLayout() {
        if case .playlist = kind { kind = .playlist(model.playlist.steps) }
        let newMode: Mode = shadeWanted ? .shade : .normal
        let modeChanged = newMode != mode
        mode = newMode
        let scale = model.scale
        layoutScale = scale
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
        if case .playlist(let steps) = kind {
            playlistOverlays?.layout(PlaylistLayout(steps: steps), scale: scale, height: pixelSize.height, shaded: mode == .shade)
        }
        let barHeight = min(kind.titleBarHeight, skinSize.height) * scale
        dragView.frame = NSRect(x: 0, y: pixelSize.height - barHeight, width: pixelSize.width, height: barHeight)
        dragView.excludedRects = kind.dragExclusions(mode).map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        window.invalidateShadow()
        // Winamp lets an unshaded window hang off the bottom of the screen; here it is pushed back on.
        if modeChanged, window.isVisible, let screen = window.screen {
            window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: true)
        }
    }

    // MARK: TitleBarDragging

    func dragBegan() {
        model.playlist.openMenu = nil
        coordinator?.dragBegan(self)
    }

    func drag(to proposedOrigin: NSPoint) {
        if let coordinator { coordinator.drag(self, to: proposedOrigin) } else { window.setFrameOrigin(proposedOrigin) }
    }

    func dragEnded() { coordinator?.dragEnded(self) }
    func titleBarDoubleClicked() {
        switch kind {
        case .main: model.toggleMainWindowShade()
        case .equalizer: model.toggleEQWindowShade()
        case .playlist: model.togglePlaylistWindowShade()
        }
    }

    // MARK: NSWindowDelegate

    func windowDidChangeBackingProperties(_ notification: Notification) {
        applyLayout()
    }

    /// A playlist menu closes when the window stops being key.
    func windowDidResignKey(_ notification: Notification) {
        model.playlist.openMenu = nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
