import AppKit
import Foundation
import MediaAccessibility
import VisualizationKit

/// The system settings the visualization follows (#0242, design §7). Debug launch arguments stand in for them.
struct VisAccessibilityInputs: Equatable {
    var reduceMotion = false
    var dimFlashing = false
    var voiceOver = false

    /// The system's settings now, each replaced by its Debug stand-in when one was passed.
    static func system(overrides configuration: RoadieConfiguration) -> VisAccessibilityInputs {
        let workspace = NSWorkspace.shared
        return VisAccessibilityInputs(
            reduceMotion: configuration.visReduceMotion ?? workspace.accessibilityDisplayShouldReduceMotion,
            dimFlashing: configuration.visDimFlashing ?? MADimFlashingLightsEnabled(),
            voiceOver: configuration.visVoiceOver ?? workspace.isVoiceOverEnabled)
    }
}

/// What the window does for Reduce Motion, Dim Flashing Lights and VoiceOver (#0242, design §7): one pure function.
struct VisualizationAccessibilityPolicy: Equatable {
    var suspendsAutoAdvance = false
    var hardCutBecomesBlend = false
    /// Every preset change blends at least this long (0: no minimum).
    var minimumBlend: TimeInterval = 0
    var crossfadeOnly = false
    var dimsPicture = false
    var overlayNeverHides = false
    var announcesPresetChanges = false
    var animatesOverlay = true

    static func make(
        reduceMotion: Bool, dimFlashing: Bool, voiceOver: Bool, changeWithReduceMotion: Bool
    ) -> VisualizationAccessibilityPolicy {
        VisualizationAccessibilityPolicy(
            suspendsAutoAdvance: reduceMotion && !changeWithReduceMotion,
            hardCutBecomesBlend: reduceMotion || dimFlashing,
            minimumBlend: dimFlashing ? VisualizationSettings.reducedMotionMinimumBlend : 0,
            crossfadeOnly: reduceMotion || dimFlashing,
            dimsPicture: dimFlashing,
            overlayNeverHides: voiceOver,
            announcesPresetChanges: voiceOver,
            animatesOverlay: !reduceMotion)
    }

    static func make(_ inputs: VisAccessibilityInputs, changeWithReduceMotion: Bool) -> VisualizationAccessibilityPolicy {
        make(
            reduceMotion: inputs.reduceMotion, dimFlashing: inputs.dimFlashing, voiceOver: inputs.voiceOver,
            changeWithReduceMotion: changeWithReduceMotion)
    }

    /// A preset change's blend under this policy: a cut becomes the key blend, and nothing is shorter than the minimum.
    func transition(_ requested: TimeInterval) -> TimeInterval {
        var transition = requested
        if transition <= 0, hardCutBecomesBlend { transition = VisualizationSettings.keyBlend }
        return transition > 0 || minimumBlend > 0 ? max(transition, minimumBlend) : transition
    }
}

/// Reduce Motion, Dim Flashing Lights, VoiceOver and the one-time flashing notice (#0242, design §7).
extension VisualizationModel {
    static let flashNoticeText = "Some visualizations flash or change quickly. If flashing lights affect you, turn on "
        + "Reduce Motion or Dim Flashing Lights in System Settings › Accessibility."

    /// The picture sits under the 40 % black layer: Dim Flashing Lights, or the flashing notice is up.
    var isPictureDimmed: Bool { accessibility.dimsPicture || isFlashNoticeUp }

    /// Auto-advance is paused now, for any reason (the probe's `autoAdvance`).
    var isAutoAdvanceSuspended: Bool { hasSuspensions }

    /// Reads the inputs again and applies the policy: auto-advance, crossfades, the VoiceOver overlay hold.
    func refreshAccessibility() {
        let inputs = accessibilityInputs()
        if inputs != accessibilityState { accessibilityState = inputs }
        let policy = VisualizationAccessibilityPolicy.make(inputs, changeWithReduceMotion: settings.changeWithReduceMotion)
        if policy != accessibility { accessibility = policy }
        setSuspended(.reduceMotion, policy.suspendsAutoAdvance)
        renderer?.setReducedMotion(policy.crossfadeOnly)
        setOverlayHold(.voiceOver, policy.overlayNeverHides)
    }

    /// Watches the three system settings; each change calls `refreshAccessibility`.
    func observeAccessibility() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        accessibilityObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAccessibility() } })
        accessibilityObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name(kMADimFlashingLightsChangedNotification as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAccessibility() } })
        accessibilityObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kMADimFlashingLightsChangedNotification as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAccessibility() } })
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAccessibility() }
        }
    }

    /// A VoiceOver announcement of `text` (a preset changed by key or list, a song title shown); nothing without it.
    func announceForVoiceOver(_ text: String) {
        guard accessibility.announcesPresetChanges else { return }
        announce(text)
    }

    // MARK: Flashing notice

    /// From the window's `show()`: the first time ever, the notice comes up, dimming the picture, pausing
    /// auto-advance and holding the overlay until Continue.
    func presentFlashNoticeIfNeeded() {
        guard !settings.flashNoticeShown, !isFlashNoticeUp else { return }
        isFlashNoticeUp = true
        setSuspended(.notice, true)
        setOverlayHold(.notice, true)
    }

    /// Continue (or Return): never again.
    func dismissFlashNotice() {
        guard isFlashNoticeUp else { return }
        updateSettings { $0.flashNoticeShown = true }
        isFlashNoticeUp = false
        setSuspended(.notice, false)
        setOverlayHold(.notice, false)
    }
}
