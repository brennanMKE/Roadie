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
                Button("Open Skin…") { model.isImporting = true }
                    .keyboardShortcut("o")
            }
        }
    }
}
