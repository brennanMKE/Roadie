import SkinKit
import SwiftUI

/// The song title in the text.bmp font: a 154x6 window at (111, 24) onto a looping strip that steps 5 px
/// every 220 ms (Webamp's Marquee.tsx). Dragging moves it by hand; stepping resumes a second after release.
struct MarqueeView: View {
    let skin: Skin
    let text: String

    @State private var step = 0
    @State private var dragPixels = 0
    @State private var dragging = false
    @State private var stepping = true

    var body: some View {
        let offset = MarqueeLayout.stepOffset(text: text, step: step, pixels: dragPixels)
        ZStack(alignment: .topLeading) {
            if let image = skin.textImage(MarqueeLayout.loopText(text)) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .offset(x: CGFloat(-offset))
            }
        }
        .frame(width: CGFloat(MarqueeLayout.width), height: 6, alignment: .topLeading)
        .clipped()
        // The 154x12 hit target Webamp gets from `padding: 3px 0`.
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    dragging = true
                    // Replaces, never accumulates: Webamp's setDragOffset(-diff). It persists after release.
                    dragPixels = -Int(value.translation.width.rounded())
                }
                .onEnded { _ in dragging = false }
        )
        .offset(x: 111, y: 21)
        .task(id: stepping) {
            guard stepping else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: MarqueeLayout.stepInterval)
                if !Task.isCancelled { step += 1 }
            }
        }
        .task(id: dragging) {
            if dragging {
                stepping = false
            } else {
                try? await Task.sleep(for: MarqueeLayout.resumeDelay)
                if !Task.isCancelled { stepping = true }
            }
        }
    }
}
