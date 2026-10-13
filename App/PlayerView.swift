import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let skin = model.skin {
                MainWindowView(skin: skin)
                    .scaleEffect(model.scale, anchor: .topLeading)
                    .frame(width: 275 * model.scale, height: 116 * model.scale, alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("No Skin Loaded", systemImage: "paintpalette")
                } description: {
                    Text(model.errorMessage ?? "Drop a .wsz file here or choose File › Open Skin…")
                } actions: {
                    Button("Open Skin…") { model.isImporting = true }
                }
                .frame(width: 275 * model.scale, height: 116 * model.scale)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let skin = urls.first { $0.pathExtension.lowercased() == "wsz" }
            let others = urls.filter { $0.pathExtension.lowercased() != "wsz" }
            if let skin { model.loadSkin(from: skin) }
            if !others.isEmpty { model.importLocalFiles(others, replace: false) }
            return skin != nil || !others.isEmpty
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.wsz, .zip]) { result in
            if case .success(let url) = result { model.loadSkin(from: url) }
        }
    }
}

extension UTType {
    /// Declared in the app's Info.plist (UTExportedTypeDeclarations). A dynamic type built from the
    /// extension never matches the dynamic type Launch Services gives the file, so the panel greys it out.
    static let wsz = UTType(exportedAs: "com.brennanmke.skinamp.wsz", conformingTo: .zip)
}
