import SkinKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Group {
            if let skin = model.skin {
                MainWindowView(skin: skin)
                    .scaleEffect(model.scale, anchor: .topLeading)
                    .frame(
                        width: MainWindowLayout.size.width * model.scale, height: MainWindowLayout.size.height * model.scale,
                        alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("No Skin Loaded", systemImage: "paintpalette")
                } description: {
                    Text(model.placeholderText)
                } actions: {
                    Button("Open Skin…") { model.openSkin() }
                }
                .frame(width: MainWindowLayout.size.width * model.scale, height: MainWindowLayout.size.height * model.scale)
                .background(.windowBackground, in: .rect(cornerRadius: 8))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls, replace: false)
        }
    }
}

extension UTType {
    /// Declared in the app's Info.plist (UTExportedTypeDeclarations). A dynamic type built from the
    /// extension never matches the dynamic type Launch Services gives the file, so the panel greys it out.
    static let wsz = UTType(exportedAs: "com.brennanmke.skinamp.wsz", conformingTo: .zip)
}
