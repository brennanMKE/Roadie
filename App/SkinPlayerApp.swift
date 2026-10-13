import SwiftUI

@main
struct SkinPlayerApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        Window("Skin Player", id: "main") {
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
