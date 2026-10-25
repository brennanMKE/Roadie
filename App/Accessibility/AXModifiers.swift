import SwiftUI

extension View {
    /// A skinned control's identifier and label, and `.isSelected` when on. Accessibility modifiers draw nothing and
    /// don't change hit-testing (#0199).
    func skinControl(_ id: String, label: String, selected: Bool = false) -> some View {
        accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One accessibility element for a display: its identifier, label and value. It's static text because SwiftUI
    /// (macOS) puts `accessibilityValue` in `AXValue` only for static text; on a bare `.ignore` element the role is
    /// `AXUnknown` and the value goes to `AXValueDescription`, which XCUITest's `value` can't read (#0200).
    func skinDisplay(_ id: String, label: String, value: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// An invisible, non-hit-testable accessibility element of `size` at `origin` (skin pixels), for displays whose sprites
/// come and go with the state (the time while stopped, the kbps digits) so the element is always there.
struct AXMarker: View {
    let id: String
    let label: String
    let value: String
    let frame: CGRect

    var body: some View {
        Color.clear
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .allowsHitTesting(false)
            .skinDisplay(id, label: label, value: value)
            .offset(x: frame.minX, y: frame.minY)
    }
}
