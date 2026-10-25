import AppKit
import ImageIO
import SkinBrowser
import SkinMuseum
import SwiftUI

/// One Museum skin: its screenshot, name, a "Downloaded" badge and Download / Apply / progress / Retry (#0126).
struct MuseumCellView: View {
    @Environment(PlayerModel.self) private var player
    let skin: MuseumSkin
    @State private var image: CGImage?

    var body: some View {
        let museum = player.museumBrowser
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(275.0 / 116.0, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        .aspectRatio(275.0 / 116.0, contentMode: .fit)
                        .overlay {
                            Text(skin.displayName).font(.caption).lineLimit(2).padding(4).foregroundStyle(.secondary)
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                if museum.isDownloaded(skin) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.regularMaterial))
                        .background(Capsule().fill(Color.green.opacity(0.35)))
                        .padding(4)
                        .accessibilityLabel("Downloaded")
                        .accessibilityIdentifier("skins.museum.downloaded.\(skin.md5)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { runPrimary(museum) }
            HStack(spacing: 4) {
                Text(skin.displayName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                actionButton(museum)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption)
        }
        .help(helpText(museum))
        .contextMenu {
            Button("Open in Skin Museum") { player.open(external: skin.museumURL) }
            if let url = museum.downloaded[skin.md5] {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Move to Trash") { player.trashDownloadedMuseumSkin(at: url) }
            }
        }
        .task(id: skin.md5) {
            image = nil
            guard let data = await museum.screenshot(for: skin), !Task.isCancelled else { return }
            image = Self.decode(data)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(skin.displayName)
        .accessibilityValue(museum.isDownloaded(skin) ? "Downloaded" : "")
        .accessibilityIdentifier("skins.museum.cell.\(skin.md5)")
    }

    private func actionButton(_ museum: MuseumBrowserModel) -> some View {
        Group {
            switch museum.downloads[skin.md5] {
            case .running:
                ProgressView().controlSize(.mini)
            case .failed:
                Button("Retry") { runPrimary(museum) }
            case nil:
                Button(museum.isDownloaded(skin) ? "Apply" : "Download") { runPrimary(museum) }
            }
        }
        .controlSize(.small)
        .accessibilityIdentifier("skins.museum.action.\(skin.md5)")
    }

    private func helpText(_ museum: MuseumBrowserModel) -> String {
        if case .failed(let message) = museum.downloads[skin.md5] { return message }
        return skin.filename
    }

    private func runPrimary(_ museum: MuseumBrowserModel) {
        if museum.primaryAction(for: skin) == .needsFolder {
            player.skinLibrary.chooseFolder()
        }
    }

    /// The cache hands back PNG data; decoding stays in the app so SkinMuseum needs no ImageIO.
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
