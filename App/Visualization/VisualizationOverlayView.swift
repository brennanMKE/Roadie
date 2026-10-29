import AppKit
import SwiftUI
import VisualizationKit

/// The song overlay's card (#0238, design §2.4): bottom-centre over the picture, gone while the idle timer has it
/// hidden. Its hosting view sits above the renderer's view and takes clicks only over the card.
struct VisualizationOverlayCard: View {
    let model: VisualizationModel

    var body: some View {
        ZStack {
            if model.overlay.isOverlayVisible {
                // Elapsed time once a second, not at frame rate.
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    card(model.overlayContent(at: timeline.date))
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(model.accessibility.animatesOverlay ? .easeInOut(duration: 0.25) : nil, value: model.overlay.isOverlayVisible)
    }

    private func card(_ content: VisualizationOverlayContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presetLine)
                .font(.caption)
                .opacity(0.75)
            Text(content.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .skinDisplay(AXID.Vis.Overlay.title, label: content.title, value: content.title)
            if let artist = content.artistLine {
                Text(artist)
                    .font(.body)
                    .lineLimit(1)
                    .skinDisplay(AXID.Vis.Overlay.artist, label: artist, value: artist)
            }
            HStack(spacing: 8) {
                Text(content.stateSymbol)
                    .skinDisplay(AXID.Vis.Overlay.state, label: content.stateLabel, value: content.stateLabel)
                if let elapsed = content.elapsed {
                    HStack(spacing: 8) {
                        Text(VisualizationOverlayContent.clock(elapsed)).monospacedDigit()
                        if let progress = content.progress {
                            ProgressView(value: progress).progressViewStyle(.linear).tint(.white).frame(maxWidth: .infinity)
                        }
                        if let trailing = content.trailingTime { Text(trailing).monospacedDigit() }
                    }
                    .skinDisplay(AXID.Vis.Overlay.time, label: content.timeLabel ?? "", value: content.timeLabel ?? "")
                }
            }
            .font(.callout)
            if let next = content.next {
                Text(next)
                    .font(.callout)
                    .lineLimit(1)
                    .skinDisplay(AXID.Vis.Overlay.next, label: next, value: next)
            }
            Text(content.outputLine)
                .font(.callout)
                .opacity(0.85)
                .skinDisplay(AXID.Vis.Overlay.output, label: content.outputLine, value: content.outputLine)
            if let note = content.note {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .skinDisplay(AXID.Vis.Overlay.note, label: note, value: note)
            }
            if model.showsOverlayKeyHint {
                Text("← → presets · Space next · L list · F1 help")
                    .font(.caption)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)))
        .onHover { model.setOverlayHold(.pointerOnOverlay, $0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Vis.overlay)
        .accessibilityLabel("Now playing")
    }

    private var presetLine: String {
        var parts = [model.currentPreset?.name ?? ""]
        parts.append(model.navigator.order == .random ? "Random" : "In order")
        if model.navigator.isLocked { parts.append("🔒") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// "No audio on this Mac", bottom-left, whenever a speaker plays, card or no card.
struct VisualizationNoAudioBadge: View {
    let model: VisualizationModel

    var body: some View {
        if case .remote = model.audioSource {
            Text("No audio on this Mac")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .padding(6)
                .skinDisplay(AXID.Vis.noAudioBadge, label: "No audio on this Mac", value: "No audio on this Mac")
                .padding(.leading, 8)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

/// A hosting view filling the picture that never takes a click, so double-click and right-click reach the host view;
/// the card's hover still works through SwiftUI's own tracking.
final class VisualizationOverlayHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
