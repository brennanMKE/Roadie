import SkinKit
import SwiftUI

/// The 76x16 visualizer at (24, 43). Clicking cycles spectrum, oscilloscope, off, like Winamp.
/// Reads `model.image` itself so only this view updates at display rate.
struct VisualizerView: View {
    let model: VisualizerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
            }
        }
        .frame(
            width: MainWindowLayout.visualizer.width, height: MainWindowLayout.visualizer.height, alignment: .topLeading)
        .contentShape(Rectangle())   // clickable even when nothing is drawn (Winamp cycles while stopped)
        .onTapGesture { model.cycleMode() }
    }
}
