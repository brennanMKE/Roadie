import AppKit
import SkinKit
import SwiftUI

/// The clutter bar's five buttons (Webamp `ClutterBar.tsx`, acting as Winamp's): O options menu, A always on top,
/// I file info, D double size, V visualizer menu. The unpressed buttons are in the base image; each draws its
/// `_SELECTED` sprite while pressed, and A and D also while on. Rects are absolute, so this view is not offset.
struct ClutterBarView: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model
    @Environment(\.skinWindow) private var window

    var body: some View {
        ZStack(alignment: .topLeading) {
            button(.mainMenu, AXID.Main.Clutter.o, "Options") { window?.popUpMainMenu(atSkinPoint: Self.below(.mainMenu)) }
            button(.alwaysOnTop, AXID.Main.Clutter.a, "Always on Top", selected: model.isAlwaysOnTop, action: model.toggleAlwaysOnTop)
            button(.fileInfo, AXID.Main.Clutter.i, "File Info", action: model.showFileInfo)
            button(.doubleSize, AXID.Main.Clutter.d, "Double Size", selected: model.isDoubleSize, action: model.toggleDoubleSize)
            button(.visualizer, AXID.Main.Clutter.v, "Visualizer Menu") { window?.popUp(visualizerMenu(), atSkinPoint: Self.below(.visualizer)) }
        }
    }

    /// The bottom-left of a button: where its menu drops from (Webamp `ContextMenuTarget bottom`).
    private static func below(_ button: MainWindowLayout.ClutterButton) -> CGPoint {
        let rect = MainWindowLayout.rect(button)
        return CGPoint(x: rect.minX, y: rect.maxY)
    }

    private func visualizerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let visualizer = model.visualizer
        for mode in VisualizerModel.Mode.allCases {
            let item = ActionMenuItem(title: mode.title) { visualizer.setMode(mode) }
            item.state = visualizer.mode == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func button(
        _ button: MainWindowLayout.ClutterButton, _ id: String, _ label: String, selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let origin = MainWindowLayout.rect(button).origin
        return Button(action: action) { EmptyView() }
            .buttonStyle(ClutterButtonStyle(skin: skin, button: button, selected: selected))
            .skinControl(id, label: label, selected: selected)
            .offset(x: origin.x, y: origin.y)
    }
}

struct ClutterButtonStyle: ButtonStyle {
    let skin: Skin
    let button: MainWindowLayout.ClutterButton
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let size = MainWindowLayout.rect(button).size
        ZStack(alignment: .topLeading) {
            if configuration.isPressed || selected {
                SpriteImage(skin: skin, name: MainWindowLayout.spriteName(button))
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}
