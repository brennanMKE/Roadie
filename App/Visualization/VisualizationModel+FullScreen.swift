import VisualizationKit

/// What the model asks of the window for full screen (#0237); the window controller in the app, a fake in tests.
@MainActor
protocol FullScreenToggling: AnyObject {
    /// Enters or leaves full screen; the controller reports the outcome with `VisualizationModel.setFullScreen`.
    func toggleFullScreen()
}

/// Full screen (#0237, design §2.3): ⌥Return, double-click and Esc.
extension VisualizationModel {
    /// The full-screen commands; anything else is left to the general key dispatch (returns false).
    @discardableResult
    func handleFullScreenCommand(_ command: VisCommand) -> Bool {
        switch command {
        case .toggleFullScreen:
            toggleFullScreen()
            return true
        case .escape:
            // Help, then the preset list (later issues), then full screen.
            if isHelpOpen {
                isHelpOpen = false
            } else if isListOpen {
                isListOpen = false
            } else if isFullScreen {
                toggleFullScreen()
            }
            return true
        default:
            return false
        }
    }

    /// ⌥Return or a double-click on the picture.
    func toggleFullScreen() { fullScreenController?.toggleFullScreen() }
}
