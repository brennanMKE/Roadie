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
    /// Pointer movement in this window, for the song overlay (#0238).
    private var mouseMonitor: Any?

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
        installOverlay()
        // Frame autosave writes the standard defaults, so a test launch places the window fresh every time.
        let isTest = model.configuration.defaults !== UserDefaults.standard
        if isTest || !window.setFrameUsingName(Self.autosaveName) { placeBesideSkinnedWindows() }
        if !isTest { window.setFrameAutosaveName(Self.autosaveName) }
        observeModel()
        observePresetList()
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
        visualization.showOverlay()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopLink()
        visualization.stopOverlayTimer()
        NSCursor.setHiddenUntilMouseMoves(false)
        visualization.setFullScreen(false)
        visualization.setVisible(false)
        visualization.close()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { visualization.setFullScreen(true) }
    func windowDidExitFullScreen(_ notification: Notification) { visualization.setFullScreen(false) }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(hostView)
        // The tracking area is key-window only, so a pointer that left meanwhile went unseen (#0238).
        visualization.syncPointerInside()
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
            _ = model.playbackState
            _ = visualization.isRendering
            _ = visualization.preferredFrameRate
            return (visualization.windowTitle, visualization.currentPreset?.name ?? "")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
        window?.title = title.0
        hostView.setPresetName(title.1)
        applyLinkState()
        visualization.syncOverlayPlaybackHold()
    }

    /// The song overlay (#0238): the card and the No audio badge, the pointer feeding the idle timer, and the cursor
    /// hidden only while this window is key in the active app.
    private func installOverlay() {
        let visualization = visualization
        hostView.installOverlay(
            card: VisualizationOverlayHostingView(rootView: VisualizationOverlayCard(model: visualization)),
            badge: VisualizationOverlayHostingView(rootView: VisualizationNoAudioBadge(model: visualization)))
        hostView.onPointerMoved = { [weak visualization] in visualization?.overlayPointerMoved(inside: true) }
        // The overlay's hosting views sit above the host view, so movement is also caught for the whole window here.
        // The monitor is never removed: this controller lives as long as the app (`AppDelegate.visualizationWindow`
        // caches it), the closure holds it weakly and it ignores every other window's events.
        window?.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            if let self, let window = self.window, event.window === window {
                let point = self.hostView.convert(event.locationInWindow, from: nil)
                if self.hostView.bounds.contains(point) { self.visualization.overlayPointerMoved(inside: true) }
            }
            return event
        }
        hostView.onPointerExited = { [weak visualization] in visualization?.overlayPointerExited() }
        visualization.isPointerInside = { [weak self] in self?.isPointerInside ?? false }
        // Only over the picture, in the key window of the active app (design §2.4).
        visualization.hideCursor = { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow, NSApp.isActive, self.isPointerInside else {
                return
            }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// The pointer's real position, whatever the tracking area last saw.
    private var isPointerInside: Bool {
        guard let window, window.isVisible else { return false }
        let point = hostView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return hostView.bounds.contains(point)
    }
}

// MARK: Preset list (#0240)

extension VisualizationWindowController {
    /// Shows or removes the list as `presetList` opens and closes; re-armed after each change.
    func observePresetList() {
        let list = withObservationTracking { visualization.presetList } onChange: { [weak self] in
            Task { @MainActor in self?.observePresetList() }
        }
        hostView.setPresetList(list, model: visualization)
    }
}

// MARK: Full screen (#0237)

extension VisualizationWindowController: FullScreenToggling {
    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
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
