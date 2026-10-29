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
        .animation(.easeInOut(duration: 0.25), value: model.overlay.isOverlayVisible)
    }

    private func card(_ content: VisualizationOverlayContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presetLine)
                .font(.caption)
                .opacity(0.75)
            Text(content.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier(AXID.Vis.Overlay.title)
                .accessibilityLabel(content.title)
            if let artist = content.artistLine {
                Text(artist)
                    .font(.body)
                    .lineLimit(1)
                    .accessibilityIdentifier(AXID.Vis.Overlay.artist)
                    .accessibilityLabel(artist)
            }
            HStack(spacing: 8) {
                Text(content.stateSymbol)
                    .accessibilityIdentifier(AXID.Vis.Overlay.state)
                    .accessibilityLabel(content.stateLabel)
                if let elapsed = content.elapsed {
                    HStack(spacing: 8) {
                        Text(VisualizationOverlayContent.clock(elapsed)).monospacedDigit()
                        if let progress = content.progress {
                            ProgressView(value: progress).progressViewStyle(.linear).tint(.white).frame(maxWidth: .infinity)
                        }
                        if let trailing = content.trailingTime { Text(trailing).monospacedDigit() }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(AXID.Vis.Overlay.time)
                    .accessibilityLabel(content.timeLabel ?? "")
                }
            }
            .font(.callout)
            if let next = content.next {
                Text(next)
                    .font(.callout)
                    .lineLimit(1)
                    .accessibilityIdentifier(AXID.Vis.Overlay.next)
                    .accessibilityLabel(next)
            }
            Text(content.outputLine)
                .font(.callout)
                .opacity(0.85)
                .accessibilityIdentifier(AXID.Vis.Overlay.output)
                .accessibilityLabel(content.outputLine)
            if let note = content.note {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AXID.Vis.Overlay.note)
                    .accessibilityLabel(note)
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
                .accessibilityIdentifier(AXID.Vis.noAudioBadge)
                .accessibilityLabel("No audio on this Mac")
        }
    }
}

/// A hosting view sized to its SwiftUI content, so it covers (and takes clicks over) only what it draws.
final class VisualizationOverlayHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Clicks on its transparent parts (nothing drawn) fall through to the picture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self && intrinsicContentSize.width <= 1 ? nil : hit
    }
}
