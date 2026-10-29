import AppKit

/// The visualization window's content: the renderer's view, filling it, and the preset name in a top strip (#0238
/// folds that into the overlay). The renderer's view is the accessibility image `vis.canvas`.
final class VisualizationHostView: NSView {
    let rendererView: NSView
    private let presetLabel = NSTextField(labelWithString: "")

    init(rendererView: NSView) {
        self.rendererView = rendererView
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityElement(false)

        rendererView.frame = bounds
        rendererView.autoresizingMask = [.width, .height]
        rendererView.setAccessibilityElement(true)
        rendererView.setAccessibilityRole(.image)
        rendererView.setAccessibilityLabel("Visualization")
        rendererView.setAccessibilityIdentifier(AXID.Vis.canvas)
        addSubview(rendererView)

        presetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        presetLabel.textColor = .white
        presetLabel.alphaValue = 0.85
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        presetLabel.shadow = shadow
        presetLabel.setAccessibilityIdentifier(AXID.Vis.preset)
        presetLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(presetLabel)
        NSLayoutConstraint.activate([
            presetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            presetLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setPresetName(_ name: String) {
        presetLabel.stringValue = name
        rendererView.setAccessibilityValue(name)
    }
}
