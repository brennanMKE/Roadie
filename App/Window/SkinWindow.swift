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

    /// AppKit answers `false` for borderless windows, which would leave menus without a key window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Borderless windows beep here by default. Close only hides: `isReleasedWhenClosed` is false, so
    /// `makeKeyAndOrderFront` brings the same window back.
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }
}
