import AppKit
import VisualizationKit

/// The visualization window's right-click menu (design §2.6), built from `VisKeyMap.rows`. Each item shows its key as
/// a bare key equivalent (a pop-up menu's equivalents act only while it's open, so they don't take the key from the
/// view). Commands still to come (song title, readouts, full screen, help) are listed but disabled.
/// Auto-advance pauses while it's open.
@MainActor
final class VisualizationContextMenu: NSMenu, NSMenuDelegate {
    private weak var model: VisualizationModel?

    /// The menu's commands in order; nil is a separator.
    static let layout: [VisCommand?] = [
        .nextPreset, .previousPreset, .hardCut, nil,
        .toggleOrder, .toggleLock, .presetList, nil,
        .showSongTitle, .toggleReadout(.title), .toggleReadout(.time), .toggleReadout(.preset), .toggleReadout(.fps), nil,
        .toggleFullScreen, .help,
    ]

    /// Commands that do something yet; the rest are disabled until their issue wires them.
    static let enabledCommands: Set<VisCommand> = [
        .nextPreset, .previousPreset, .hardCut, .toggleOrder, .toggleLock, .presetList, .toggleFullScreen,
    ]

    static func make(model: VisualizationModel) -> VisualizationContextMenu {
        let menu = VisualizationContextMenu(title: "Visualization")
        menu.model = model
        menu.delegate = menu
        menu.autoenablesItems = false
        for command in layout {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let title = command == .toggleFullScreen
                ? (model.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") : VisKeyMap.rows.first { $0.command == command }?.title ?? "\(command)"
            let item = VisualizationCommandItem(title: title, command: command) { [weak model] in
                model?.perform(command)
            }
            let (key, modifiers) = keyEquivalent(for: command)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabledCommands.contains(command)
            switch command {
            case .toggleOrder: item.state = model.navigator.order == .random ? .on : .off
            case .toggleLock: item.state = model.navigator.isLocked ? .on : .off
            default: break
            }
            menu.addItem(item)
        }
        return menu
    }

    /// The first key of the command's `VisKeyMap` row, as a menu key equivalent.
    static func keyEquivalent(for command: VisCommand) -> (String, NSEvent.ModifierFlags) {
        func function(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }
        switch command {
        case .nextPreset: return (function(NSRightArrowFunctionKey), [])
        case .previousPreset: return (function(NSLeftArrowFunctionKey), [])
        case .hardCut: return ("h", [])
        case .toggleOrder: return ("r", [])
        case .toggleLock: return ("`", [])
        case .presetList: return ("l", [])
        case .showSongTitle: return ("t", [])
        case .toggleReadout(.title): return (function(NSF2FunctionKey), [])
        case .toggleReadout(.time): return (function(NSF3FunctionKey), [])
        case .toggleReadout(.preset): return (function(NSF4FunctionKey), [])
        case .toggleReadout(.fps): return (function(NSF5FunctionKey), [])
        case .help: return (function(NSF1FunctionKey), [])
        case .toggleFullScreen: return ("\r", [.option])
        case .escape, .transport: return ("", [])
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        model?.setSuspended(.menu, true)
        model?.setOverlayHold(.menu, true)
    }

    func menuDidClose(_ menu: NSMenu) {
        model?.setSuspended(.menu, false)
        model?.setOverlayHold(.menu, false)
    }
}

/// A menu item that is its own target, so the menu keeps the action alive.
final class VisualizationCommandItem: NSMenuItem {
    let command: VisCommand
    private let handler: () -> Void

    init(title: String, command: VisCommand, handler: @escaping () -> Void) {
        self.command = command
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
