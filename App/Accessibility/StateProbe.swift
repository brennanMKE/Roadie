import AppKit

/// UI-test mode: `-RoadieUITest 1` (an `NSArgumentDomain` default, so `open --args` and `XCUIApplication.launchArguments`
/// both set it). Until `RoadieConfiguration` (#0194) lands this is the only switch the state probe reads.
enum UITestMode {
    static var isActive: Bool { UserDefaults.standard.bool(forKey: "RoadieUITest") }
}

/// The hidden `state.probe` element (#0199): a 1x1 static text at the main window's top-left whose value is
/// `PlayerModel.testProbe()` as JSON, computed when read. It draws nothing and never takes a click.
final class StateProbeView: NSView {
    private let probe: @MainActor () -> String

    init(probe: @escaping @MainActor () -> String) {
        self.probe = probe
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("State probe")
        setAccessibilityIdentifier(AXID.probe)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityValue() -> Any? {
        MainActor.assumeIsolated { probe() }
    }
}
