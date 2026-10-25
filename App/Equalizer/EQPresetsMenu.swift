import AudioCore
import SkinKit
import SwiftUI

/// The PRESETS button: Load > the built-in presets and "From EQF…", and Save…, as Webamp's PresetsContextMenu.
struct EQPresetsMenu: View {
    @Environment(PlayerModel.self) private var model
    let skin: Skin

    var body: some View {
        Menu {
            Menu("Load") {
                ForEach(EQPreset.builtIn) { preset in
                    Button(preset.name) { model.applyEQPreset(preset) }
                }
                Divider()
                Button("From EQF…") { model.loadEQF() }
            }
            Button("Save…") { model.saveEQF() }
        } label: {
            SpriteImage(skin: skin, name: "EQ_PRESETS_BUTTON")
                .frame(width: EQLayout.presetsButton.width, height: EQLayout.presetsButton.height, alignment: .topLeading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: EQLayout.presetsButton.width, height: EQLayout.presetsButton.height)
        .skinControl(AXID.EQ.presets, label: "Presets")
    }
}
