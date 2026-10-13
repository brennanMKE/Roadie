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
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) else { return false }
            model.loadSkin(from: url)
            return true
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.wsz, .zip]) { result in
            if case .success(let url) = result { model.loadSkin(from: url) }
        }
    }
}

extension UTType {
    static let wsz = UTType(filenameExtension: "wsz", conformingTo: .zip) ?? .zip
}
