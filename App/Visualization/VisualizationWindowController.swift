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
        startLink()
        updateVisibility()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopLink()
        visualization.setVisible(false)
        visualization.close()
    }

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

/// `CADisplayLink` retains its target, so this trampoline holds the model weakly.
@MainActor
private final class VisualizationLinkTarget: NSObject {
    weak var model: VisualizationModel?

    init(model: VisualizationModel) { self.model = model }

    @objc func tick(_ link: CADisplayLink) {
        model?.tick(now: link.timestamp)
    }
}
