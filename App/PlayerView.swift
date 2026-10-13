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
            if let url = urls.first(where: { $0.pathExtension.lowercased() == "wsz" }) {
                model.loadSkin(from: url)
                return true
            }
            let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
            guard !audio.isEmpty else { return false }
            model.playFiles(audio)
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
