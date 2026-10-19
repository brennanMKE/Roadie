import AppKit
import SkinKit

/// Builds the main window's options menu from `MainMenu`'s entries. The only `NSMenu` code for that menu.
@MainActor
enum MainMenuBuilder {
    static func menu(_ entries: [MainMenuEntry], perform: @escaping (MainMenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = Self.menu(children, perform: perform)
                submenu.title = title
                menu.addItem(item)
                menu.setSubmenu(submenu, for: item)
            case .item(let model):
                menu.addItem(ClosureMenuItem(model) { perform(model.command) })
            }
        }
        return menu
    }
}

/// A menu item that is its own target, so nothing outside the menu has to keep the targets alive.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ model: MainMenuItem, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: model.title, action: #selector(fire), keyEquivalent: model.shortcut?.key ?? "")
        target = self
        state = model.state == .on ? .on : .off
        isEnabled = model.isEnabled
        if let shortcut = model.shortcut {
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { mask.insert(.command) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.control) { mask.insert(.control) }
            keyEquivalentModifierMask = mask
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
