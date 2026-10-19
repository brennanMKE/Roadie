import AppKit

/// Borderless, non-opaque window for a skinned view. Key and main like a titled window.
final class SkinWindow: NSWindow {
    init(contentSize: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        animationBehavior = .documentWindow
    }

    /// Called after a left mouse-down anywhere in the window has been handled.
    var onLeftMouseDown: (() -> Void)?

    /// A click anywhere in the window (Webamp's `FocusTarget`), after AppKit has handled it, so a window that is already
    /// key can still pull its group forward.
    /// A secondary click (right-click, or Control-click); returning true swallows the event.
    var onRightMouseDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        let isSecondary = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isSecondary, let onRightMouseDown, onRightMouseDown(event) { return }
        super.sendEvent(event)
        if event.type == .leftMouseDown { onLeftMouseDown?() }
    }

    /// AppKit answers `false` for borderless windows, which would leave menus without a key window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Borderless windows beep here by default. Close only hides: `isReleasedWhenClosed` is false, so
    /// `makeKeyAndOrderFront` brings the same window back.
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }

    /// Window > Minimize (⌘M) beeps on a window without a minimize button; minimize directly.
    override func performMiniaturize(_ sender: Any?) {
        miniaturize(sender)
    }
}
