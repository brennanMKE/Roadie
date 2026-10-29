import AppKit
import Observation
import QuartzCore

/// The visualization window (design §2.2): a plain titled window holding `VisualizationHostView`, its display link
/// driving `VisualizationModel.tick`, and the visibility events that pause rendering.
@MainActor
final class VisualizationWindowController: NSWindowController, NSWindowDelegate {
    static let autosaveName = "VisualizationWindow"

    private let model: PlayerModel
    private var visualization: VisualizationModel { model.visualization }
    private let hostView: VisualizationHostView
    private var link: CADisplayLink?
    private var target: VisualizationLinkTarget?
    private var observers: [NSObjectProtocol] = []
    /// The windowed frame, style and level while in the Debug borderless full screen (#0237).
    var borderlessSaved: BorderlessSaved?

    init(model: PlayerModel) {
        self.model = model
        let renderer = model.visualization.prepareRenderer()
        hostView = VisualizationHostView(rendererView: renderer.view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 200)
        window.identifier = NSUserInterfaceItemIdentifier(AXID.Vis.window)
        window.setAccessibilityIdentifier(AXID.Vis.window)
        // Launch never restores full screen (#0237): the window opens windowed.
        window.isRestorable = false
        window.contentView = hostView
        super.init(window: window)
        window.delegate = self
        window.initialFirstResponder = hostView
        let visualization = model.visualization
        hostView.onCommand = { [weak visualization] in visualization?.perform($0) }
        hostView.makeContextMenu = { [weak visualization] in
            visualization.map { VisualizationContextMenu.make(model: $0) }
        }
        visualization.onKeyChange = { [weak host = hostView] in host?.showToast($0.name) }
        visualization.fullScreenController = self
        hostView.onDoubleClick = { [weak visualization] in visualization?.toggleFullScreen() }
        // Frame autosave writes the standard defaults, so a test launch places the window fresh every time.
        let isTest = model.configuration.defaults !== UserDefaults.standard
        if isTest || !window.setFrameUsingName(Self.autosaveName) { placeBesideSkinnedWindows() }
        if !isTest { window.setFrameAutosaveName(Self.autosaveName) }
        observeModel()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibility() } })
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Right of the skinned windows, top-aligned with them (first placement, no saved frame).
    private func placeBesideSkinnedWindows() {
        guard let window else { return }
        let skinned = NSApp.windows.filter { $0 is SkinWindow && $0.isVisible }.map(\.frame)
        let group = skinned.reduce(CGRect.null) { $0.union($1) }
        if group.isNull {
            window.center()
        } else {
            window.setFrameTopLeftPoint(NSPoint(x: group.maxX + 8, y: group.maxY))
        }
    }

    func show() {
        guard let window else { return }
        window.title = visualization.windowTitle
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostView)
        startLink()
        updateVisibility()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopLink()
        if let saved = borderlessSaved { restoreFromBorderless(saved) }
        visualization.setFullScreen(false)
        visualization.setVisible(false)
        visualization.close()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { visualization.setFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { visualization.setFullScreen(false) }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(hostView)
    }

    func windowDidMiniaturize(_ notification: Notification) { updateVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateVisibility() }

    // MARK: Rendering

    private func updateVisibility() {
        guard let window else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            && !NSApp.isHidden
        visualization.setVisible(visible)
        applyLinkState()
    }

    private func startLink() {
        guard link == nil else { return }
        let target = VisualizationLinkTarget(model: visualization)
        self.target = target
        let link = hostView.displayLink(target: target, selector: #selector(VisualizationLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        applyLinkState()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        target = nil
    }

    private func applyLinkState() {
        guard let link else { return }
        let rate = visualization.preferredFrameRate
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: rate)
        link.isPaused = !visualization.isRendering
    }

    /// Title, preset name and the link's rate and pause follow the model; re-armed after each change.
    private func observeModel() {
        let title = withObservationTracking {
            _ = visualization.isRendering
            _ = visualization.preferredFrameRate
            return (visualization.windowTitle, visualization.currentPreset?.name ?? "")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
        window?.title = title.0
        hostView.setPresetName(title.1)
        applyLinkState()
    }
}

// MARK: Full screen (#0237)

extension VisualizationWindowController: FullScreenToggling {
    func toggleFullScreen() {
        guard let window else { return }
        #if DEBUG
        if model.configuration.visFullScreenBorderless {
            if let saved = borderlessSaved {
                restoreFromBorderless(saved)
                visualization.setFullScreen(false)
            } else {
                enterBorderless(window)
                visualization.setFullScreen(true)
            }
            return
        }
        #endif
        window.toggleFullScreen(nil)
    }

    /// The Debug `-RoadieVisFullScreen borderless` path: a screen-sized borderless window above the menu bar.
    fileprivate func enterBorderless(_ window: NSWindow) {
        borderlessSaved = BorderlessSaved(frame: window.frame, styleMask: window.styleMask, level: window.level)
        let screen = window.screen ?? NSScreen.main
        window.styleMask = [.borderless]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        if let screen { window.setFrame(screen.frame, display: true) }
        window.makeFirstResponder(hostView)
    }

    func restoreFromBorderless(_ saved: BorderlessSaved) {
        guard let window else { return }
        borderlessSaved = nil
        window.styleMask = saved.styleMask
        window.level = saved.level
        window.setFrame(saved.frame, display: true)
        window.makeFirstResponder(hostView)
    }
}

struct BorderlessSaved {
    var frame: NSRect
    var styleMask: NSWindow.StyleMask
    var level: NSWindow.Level
}

/// `CADisplayLink` retains its target, so this trampoline holds the model weakly.
@MainActor
private final class VisualizationLinkTarget: NSObject {
    weak var model: VisualizationModel?

    init(model: VisualizationModel) { self.model = model }

    @objc func tick(_ link: CADisplayLink) {
        model?.tick(now: link.timestamp)
    }
}
