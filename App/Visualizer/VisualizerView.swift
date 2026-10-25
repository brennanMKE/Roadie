import SkinKit
import SwiftUI

/// The visualizer: 76x16 at (24, 43) in the main window, 76x5 in the shade strip. Clicking cycles spectrum,
/// oscilloscope, off, like Winamp. Reads `model.image` itself so only this view updates at display rate. The shade
/// image is 152x10 when the window is doubled, drawn at `pointScale` 2 so it lands 1:1 under the window's scale.
struct VisualizerView: View {
    let model: VisualizerModel
    var size = MainWindowLayout.visualizer.size
    var axID = AXID.Main.visualizer

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = model.image {
                Image(decorative: image, scale: CGFloat(model.pointScale))
                    .interpolation(.none)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())   // clickable even when nothing is drawn (Winamp cycles while stopped)
        .onTapGesture { model.cycleMode() }
        .skinDisplay(axID, label: "Visualizer", value: model.mode.accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }
}
