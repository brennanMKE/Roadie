import AppKit
import SwiftUI
import VisualizationKit

/// The one-time flashing notice (#0242, design §7): a centred card over the dimmed picture with Continue.
struct VisualizationFlashNoticeView: View {
    let model: VisualizationModel

    var body: some View {
        ZStack {
            if model.isFlashNoticeUp {
                Color.clear.contentShape(Rectangle())
                card
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(spacing: 16) {
            Text(VisualizationModel.flashNoticeText)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .skinDisplay(
                    "vis.flashNotice.text", label: VisualizationModel.flashNoticeText,
                    value: VisualizationModel.flashNoticeText)
            Button("Continue") { model.dismissFlashNotice() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AXID.Vis.flashNoticeContinue)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.75))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)))
        .environment(\.colorScheme, .dark)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Vis.flashNotice)
        .accessibilityLabel("Flashing lights")
    }
}

/// The notice's hosting view: it takes clicks only while the notice is up.
final class VisualizationFlashNoticeHostingView: NSHostingView<VisualizationFlashNoticeView> {
    private weak var model: VisualizationModel?

    init(model: VisualizationModel) {
        self.model = model
        super.init(rootView: VisualizationFlashNoticeView(model: model))
        sizingOptions = []
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init(rootView: VisualizationFlashNoticeView) { fatalError() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        model?.isFlashNoticeUp == true ? super.hitTest(point) : nil
    }
}
