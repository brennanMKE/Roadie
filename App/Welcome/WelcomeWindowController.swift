import AppKit
import SwiftUI

/// "Welcome to Roadie" (#0169): one non-modal NSWindow hosting `WelcomeView`, centred. Closing it (the close button
/// or Continue) marks first run done.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let model: PlayerModel
    private let onDismiss: () -> Void
    private var window: NSWindow?

    init(model: PlayerModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    /// `openMuseum`: also open the Skins window on the Museum tab once the view appears (first run with no skins).
    func show(openMuseum: Bool) {
        let root = rootView(openMuseum: openMuseum)
        if let window, let hosting = window.contentView as? NSHostingView<AnyView> {
            hosting.rootView = root
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Welcome to Roadie"
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("welcome")
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { onDismiss() }

    private func rootView(openMuseum: Bool) -> AnyView {
        AnyView(
            WelcomeView(openMuseumOnAppear: openMuseum, onContinue: { [weak self] in self?.close() })
                .environment(model)
                .environment(model.skinLibrary)
                .environment(model.folderSettings)
                .environment(model.sources)
                .environment(model.fallback)
                .environment(model.musicAssistantSelection)
                .defaultAppStorage(model.defaults))
    }
}
