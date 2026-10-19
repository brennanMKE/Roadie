import AppKit
import AudioCore
import SwiftUI

/// The non-modal File Info panel (the clutter bar's I; the playlist reuses it). One panel, its content swapped per
/// track. Not `NSAlert.runModal`, which would stall the visualizer's run loop.
@MainActor
final class FileInfoPanel {
    static let shared = FileInfoPanel()

    private var panel: NSPanel?

    func show(_ info: TrackInfo) {
        let panel = self.panel ?? makePanel()
        (panel.contentView as? NSHostingView<FileInfoView>)?.rootView = FileInfoView(info: info)
        if self.panel == nil {
            self.panel = panel
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: true)
        panel.title = "File Info"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: FileInfoView(info: TrackInfo(title: "", artist: "")))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        return panel
    }
}

struct FileInfoView: View {
    let info: TrackInfo

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(info.rows, id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(row.value).monospacedDigit().textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}
