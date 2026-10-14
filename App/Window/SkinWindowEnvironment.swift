import SwiftUI

private struct SkinWindowKey: EnvironmentKey {
    static var defaultValue: SkinWindowController? { nil }
}

extension EnvironmentValues {
    /// The window hosting the player. nil in previews and offscreen renders, where title-bar buttons are inert.
    var skinWindow: SkinWindowController? {
        get { self[SkinWindowKey.self] }
        set { self[SkinWindowKey.self] = newValue }
    }
}
