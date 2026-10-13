import SwiftUI

@main
struct SkinAmpApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        Window("SkinAmp", id: "main") {
            PlayerView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openAudioFiles(replace: true) }
                    .keyboardShortcut("o")
                Button("Add to Playlist…") { model.openAudioFiles(replace: false) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Open Skin…") { model.isImporting = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
