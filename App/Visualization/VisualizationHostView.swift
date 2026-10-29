import AppKit
import VisualizationKit

/// The visualization window's content: the renderer's view, filling it, and the preset name in a top strip (#0238
/// folds that into the overlay). The renderer's view is the accessibility image `vis.canvas`.
final class VisualizationHostView: NSView {
    let rendererView: NSView
    private let presetLabel = NSTextField(labelWithString: "")
    private let toast = NSTextField(labelWithString: "")
    private var toastGeneration = 0
    /// A key that maps to a visualization command (design §2.5).
    var onCommand: ((VisCommand) -> Void)?
    /// The right-click / control-click menu (design §2.6).
    var makeContextMenu: (() -> NSMenu?)?

    init(rendererView: NSView) {
        self.rendererView = rendererView
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(false)

        rendererView.frame = bounds
        rendererView.autoresizingMask = [.width, .height]
        rendererView.setAccessibilityElement(true)
        rendererView.setAccessibilityRole(.image)
        rendererView.setAccessibilityLabel("Visualization")
        rendererView.setAccessibilityIdentifier(AXID.Vis.canvas)
        addSubview(rendererView)

        presetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        presetLabel.textColor = .white
        presetLabel.alphaValue = 0.85
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        presetLabel.shadow = shadow
        presetLabel.setAccessibilityIdentifier(AXID.Vis.preset)
        presetLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(presetLabel)
        NSLayoutConstraint.activate([
            presetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            presetLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])

        toast.font = .systemFont(ofSize: 13, weight: .semibold)
        toast.textColor = .white
        toast.alignment = .center
        toast.drawsBackground = false
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        toast.layer?.cornerRadius = 6
        toast.alphaValue = 0
        toast.isHidden = true
        toast.setAccessibilityIdentifier(AXID.Vis.toast)
        toast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: centerXAnchor),
            toast.topAnchor.constraint(equalTo: topAnchor, constant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Song overlay (#0238)

    /// Pointer movement inside the view and its leaving, for the overlay's idle timer.
    var onPointerMoved: (() -> Void)?
    var onPointerExited: (() -> Void)?

    /// Adds the overlay's views (`VisualizationOverlayView.swift`) above the renderer's view.
    func installOverlay(card: NSView, badge: NSView) {
        for view in [badge, card] {
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onPointerMoved?() }
    override func mouseEntered(with event: NSEvent) { onPointerMoved?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }

    // MARK: Keys, mouse and menu

    /// A double-click on the picture (single clicks do nothing) (#0237).
    var onDoubleClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = Self.visKey(for: event)
        if let key, let onCommand,
            let command = Self.command(for: key, flags: flags, isRepeat: event.isARepeat)
        {
            onCommand(command)
            return
        }
        // A held command key (→, Space, a letter): its repeats do nothing, without a beep each time.
        if let key, onCommand != nil, Self.swallowsRepeat(of: key, flags: flags, isRepeat: event.isARepeat) { return }
        super.keyDown(with: event)
    }

    private static func command(for key: VisKey, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> VisCommand? {
        VisKeyMap.command(
            for: key, command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option), shift: flags.contains(.shift), isRepeat: isRepeat)
    }

    /// An auto-repeat that maps to nothing, of a key whose first press is a command.
    static func swallowsRepeat(of key: VisKey, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        isRepeat && command(for: key, flags: flags, isRepeat: true) == nil
            && command(for: key, flags: flags, isRepeat: false) != nil
    }

    /// Esc arrives as `cancelOperation` when the key isn't handled as a key-down first.
    override func cancelOperation(_ sender: Any?) {
        if let onCommand { onCommand(.escape) } else { super.cancelOperation(sender) }
    }

    /// The `NSEvent` as a `VisKey`: special keys by `specialKey`, else the characters ignoring modifiers.
    static func visKey(for event: NSEvent) -> VisKey? {
        if let special = event.specialKey {
            switch special {
            case .leftArrow: return .left
            case .rightArrow: return .right
            case .upArrow: return .up
            case .downArrow: return .down
            case .delete, .backspace: return .delete
            case .carriageReturn, .enter, .newline: return .returnKey
            case .f1: return .function(1)
            case .f2: return .function(2)
            case .f3: return .function(3)
            case .f4: return .function(4)
            case .f5: return .function(5)
            default: break
            }
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return nil }
        switch text {
        case " ": return .space
        case "\u{1b}": return .escape
        case "\u{7f}", "\u{8}": return .delete
        case "\r", "\u{3}": return .returnKey
        default: return .character(text)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu?() ?? super.menu(for: event)
    }

    // MARK: Labels

    /// The preset name, top-centre, for 2 s, fading (a key change).
    func showToast(_ name: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast.stringValue = "  \(name)  "
        toast.setAccessibilityLabel(name)
        toast.isHidden = false
        toast.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, generation == self.toastGeneration else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.toast.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if generation == self.toastGeneration { self.toast.isHidden = true }
                }
            })
        }
    }

    func setPresetName(_ name: String) {
        presetLabel.stringValue = name
        rendererView.setAccessibilityValue(name)
    }
}
