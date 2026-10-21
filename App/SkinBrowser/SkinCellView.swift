import SkinBrowser
import SkinLibrary
import SwiftUI

struct SkinCellView: View {
    @Environment(PlayerModel.self) private var player
    let record: SkinRecord
    @State private var image: CGImage?

    var body: some View {
        let browser = player.skinBrowser
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
                        .overlay { Text(record.name).font(.caption).lineLimit(2).padding(4).foregroundStyle(.secondary) }
                }
            }
            .overlay {
                if record.id == browser.currentSkinID {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            HStack(spacing: 4) {
                Text(record.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                badge
            }
            .font(.caption)
        }
        .opacity(record.status == .failed ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { browser.apply(record) }
        .allowsHitTesting(record.status != .failed)
        .contextMenu {
            Button("Move to Trash") { browser.moveToTrash(record) }
                .accessibilityIdentifier("skins.cell.trash")
        }
        .help(record.status == .ok ? "" : record.warnings.joined(separator: "\n"))
        .task(id: record.hash) {
            image = nil
            guard record.status != .failed else { return }
            image = await browser.thumbnail(for: record)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("skins.cell")
    }

    @ViewBuilder
    private var badge: some View {
        switch record.status {
        case .partial: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red)
        case .ok: EmptyView()
        }
        if record.fileCount > 1 {
            Label("\(record.fileCount)", systemImage: "doc.on.doc").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
        }
    }
}
