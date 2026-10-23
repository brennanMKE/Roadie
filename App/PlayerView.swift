import SkinKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let skin = model.skin {
                MainWindowView(skin: skin)
                    .scaleEffect(model.scale, anchor: .topLeading)
                    .frame(
                        width: MainWindowLayout.size.width * model.scale, height: model.mainWindowSkinSize.height * model.scale,
                        alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("No Skin Loaded", systemImage: "paintpalette")
                } description: {
                    Text(model.placeholderText)
                } actions: {
                    HStack {
                        Button("Open Skin…") { model.openSkin() }
                        Button("Browse the Skin Museum…") {
                            model.pendingSkinsSource = .museum
                            openWindow(id: "skins")
                        }
                        .accessibilityIdentifier("player.browseMuseum")
                    }
                }
                .frame(width: MainWindowLayout.size.width * model.scale, height: model.mainWindowSkinSize.height * model.scale)
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
    static let wsz = UTType(exportedAs: "co.sstools.roadie.wsz", conformingTo: .zip)
}
