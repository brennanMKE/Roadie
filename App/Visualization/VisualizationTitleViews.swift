import AppKit
import SwiftUI
import VisualizationKit

/// The song title animation (#0239, design §2.7): centred, large, white with a soft shadow. 0.5 s fade in growing
/// from 90 %, 2 s hold, 1 s fade out; fade only under Reduce Motion. A new show replaces a running one.
struct VisualizationSongTitleView: View {
    let model: VisualizationModel

    var body: some View {
        ZStack {
            if let show = model.songTitle {
                SongTitleText(show: show, reduceMotion: model.reducesMotion).id(show.id)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct SongTitleText: View {
    let show: SongTitleShow
    let reduceMotion: Bool
    /// 0 before, 1 shown, 2 fading out.
    @State private var phase = 0

    var body: some View {
        Text(show.text)
            .font(.system(size: 40, weight: .bold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 6, y: 2)
            .opacity(phase == 1 ? 1 : 0)
            .scaleEffect(reduceMotion || phase > 0 ? 1 : 0.9)
            .skinDisplay(AXID.Vis.songTitle, label: show.text, value: show.text)
            .task {
                withAnimation(.easeOut(duration: 0.5)) { phase = 1 }
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 1)) { phase = 2 }
            }
    }
}

/// The F2–F5 corner readouts (#0239): small shadowed texts that stay when the overlay hides; while the card is up the
/// bottom two and the preset name hide (the card has them).
struct VisualizationReadoutsView: View {
    let model: VisualizationModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let content = model.overlayContent(at: timeline.date)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if model.showsReadout(.preset), let name = model.currentPreset?.name {
                        readout(name, id: AXID.Vis.Readout.preset)
                    }
                    Spacer(minLength: 16)
                    if model.showsReadout(.fps) {
                        readout("\(Int(model.measuredFPS.rounded())) fps", id: AXID.Vis.Readout.fps)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if model.showsReadout(.title) {
                        readout(model.currentSongTitleText ?? content.title, id: AXID.Vis.Readout.title)
                    }
                    Spacer(minLength: 16)
                    if model.showsReadout(.time) {
                        readout(VisualizationModel.timeReadout(content) ?? "0:00", id: AXID.Vis.Readout.time)
                    }
                }
            }
        }
        // Below the preset strip at the top-left (#0238) and clear of the No audio badge.
        .padding(.horizontal, 10)
        .padding(.top, 26)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func readout(_ text: String, id: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            .skinDisplay(id, label: text, value: text)
    }
}

/// The keyboard shortcuts card (F1 / ?, #0239): `VisKeyMap.rows` in two columns; Esc, F1, ? or a click closes it.
struct VisualizationHelpView: View {
    let model: VisualizationModel

    var body: some View {
        ZStack {
            if model.isHelpOpen {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { model.isHelpOpen = false }
                card.onTapGesture { model.isHelpOpen = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        let rows = VisKeyMap.rows
        let half = (rows.count + 1) / 2
        return VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.title3.weight(.semibold))
                .skinDisplay("vis.help.title", label: "Keyboard Shortcuts", value: "Keyboard Shortcuts")
            HStack(alignment: .top, spacing: 28) {
                column(Array(rows[..<half]))
                column(Array(rows[half...]))
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.7))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)))
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Vis.help)
        .accessibilityLabel("Keyboard Shortcuts")
    }

    private func column(_ rows: [(keys: String, title: String, command: VisCommand)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                GridRow {
                    Text(row.keys)
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .opacity(0.85)
                    Text(row.title)
                        .font(.system(size: 12))
                        .skinDisplay("vis.help.row.\(row.title)", label: row.title, value: row.keys)
                }
            }
        }
    }
}

/// The help card's hosting view: it takes clicks only while the card is open, so double-click and right-click reach
/// the picture otherwise.
final class VisualizationHelpHostingView: NSHostingView<VisualizationHelpView> {
    private weak var model: VisualizationModel?

    init(model: VisualizationModel) {
        self.model = model
        super.init(rootView: VisualizationHelpView(model: model))
        sizingOptions = []
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init(rootView: VisualizationHelpView) { fatalError() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        model?.isHelpOpen == true ? super.hitTest(point) : nil
    }
}

extension VisualizationHostView {
    /// The song title, readouts and help card (#0239), above the overlay, filling the picture.
    func installTitleViews(model: VisualizationModel) {
        let views: [NSView] = [
            VisualizationOverlayHostingView(rootView: VisualizationReadoutsView(model: model)),
            VisualizationOverlayHostingView(rootView: VisualizationSongTitleView(model: model)),
            VisualizationHelpHostingView(model: model),
            VisualizationFlashNoticeHostingView(model: model),
        ]
        for view in views {
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}
