import AppKit

/// The built-in visualizer's menu (Winamp's clutter bar V and right-click on the vis): its three modes, then
/// Start/Stop Visualization (#0235). Visualization Settings… comes in #0241.
@MainActor
enum VisualizerMenu {
    static let startStopTitle = "Start/Stop Visualization"

    static func make(model: PlayerModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let visualizer = model.visualizer
        for mode in VisualizerModel.Mode.allCases {
            let item = ActionMenuItem(title: mode.title) { visualizer.setMode(mode) }
            item.state = visualizer.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let visualization = model.visualization
        let toggle = ActionMenuItem(title: startStopTitle) { visualization.toggle() }
        toggle.keyEquivalent = "k"
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.state = visualization.isOpen ? .on : .off
        menu.addItem(toggle)
        return menu
    }
}
