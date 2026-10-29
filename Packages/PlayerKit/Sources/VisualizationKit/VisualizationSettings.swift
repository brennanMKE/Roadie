import Foundation

/// Every visualization setting the window and the Settings pane share (design §6).
public struct VisualizationSettings: Equatable, Sendable {
    public var autoAdvance: Bool
    /// Clamped to `autoAdvanceRange` on load and init.
    public var autoAdvanceSeconds: TimeInterval
    public var autoAdvanceVaries: Bool
    /// Clamped to `blendRange` on load and init.
    public var blendSeconds: TimeInterval
    public var order: PresetNavigator.Order
    public var locked: Bool
    public var lastPreset: String?
    public var presetsFolder: String?
    /// 0 = never hide.
    public var overlayIdleSeconds: TimeInterval
    public var songTitleOnTrackChange: Bool
    public var readouts: Set<VisReadout>
    public var openOnPlay: Bool
    public var windowOpen: Bool
    public var changeWithReduceMotion: Bool
    public var flashNoticeShown: Bool

    /// Blend for key and list changes.
    public static let keyBlend: TimeInterval = 1.7
    /// Minimum blend under Dim Flashing Lights (#0242).
    public static let reducedMotionMinimumBlend: TimeInterval = 5
    public static let autoAdvanceRange: ClosedRange<TimeInterval> = 5...300
    public static let blendRange: ClosedRange<TimeInterval> = 0...10

    public static let defaults = VisualizationSettings(
        autoAdvance: true, autoAdvanceSeconds: 16, autoAdvanceVaries: true, blendSeconds: 2.7, order: .random,
        locked: false, lastPreset: nil, presetsFolder: nil, overlayIdleSeconds: 3, songTitleOnTrackChange: true,
        readouts: [], openOnPlay: false, windowOpen: false, changeWithReduceMotion: false, flashNoticeShown: false
    )

    public init(
        autoAdvance: Bool, autoAdvanceSeconds: TimeInterval, autoAdvanceVaries: Bool, blendSeconds: TimeInterval,
        order: PresetNavigator.Order, locked: Bool, lastPreset: String?, presetsFolder: String?,
        overlayIdleSeconds: TimeInterval, songTitleOnTrackChange: Bool, readouts: Set<VisReadout>, openOnPlay: Bool,
        windowOpen: Bool, changeWithReduceMotion: Bool, flashNoticeShown: Bool
    ) {
        self.autoAdvance = autoAdvance
        self.autoAdvanceSeconds = Self.clamp(autoAdvanceSeconds, Self.autoAdvanceRange)
        self.autoAdvanceVaries = autoAdvanceVaries
        self.blendSeconds = Self.clamp(blendSeconds, Self.blendRange)
        self.order = order
        self.locked = locked
        self.lastPreset = lastPreset
        self.presetsFolder = presetsFolder
        self.overlayIdleSeconds = max(0, overlayIdleSeconds)
        self.songTitleOnTrackChange = songTitleOnTrackChange
        self.readouts = readouts
        self.openOnPlay = openOnPlay
        self.windowOpen = windowOpen
        self.changeWithReduceMotion = changeWithReduceMotion
        self.flashNoticeShown = flashNoticeShown
    }

    public enum Key {
        public static let autoAdvance = "visualization.autoAdvance"
        public static let autoAdvanceSeconds = "visualization.autoAdvanceSeconds"
        public static let autoAdvanceVaries = "visualization.autoAdvanceVaries"
        public static let blendSeconds = "visualization.blendSeconds"
        public static let order = "visualization.order"
        public static let locked = "visualization.locked"
        public static let lastPreset = "visualization.lastPreset"
        public static let presetsFolder = "visualization.presetsFolder"
        public static let overlayIdleSeconds = "visualization.overlayIdleSeconds"
        public static let songTitleOnTrackChange = "visualization.songTitleOnTrackChange"
        public static let readouts = "visualization.readouts"
        public static let openOnPlay = "visualization.openOnPlay"
        public static let windowOpen = "visualization.windowOpen"
        public static let changeWithReduceMotion = "visualization.changeWithReduceMotion"
        public static let flashNoticeShown = "visualization.flashNoticeShown"
    }

    public var autoAdvancePolicy: AutoAdvanceClock.Policy {
        AutoAdvanceClock.Policy(isEnabled: autoAdvance, interval: autoAdvanceSeconds, varies: autoAdvanceVaries)
    }

    /// Missing or wrong-typed keys fall back to the default; out-of-range values clamp.
    /// Strings are accepted too, since launch arguments (`NSArgumentDomain`) arrive as strings.
    public static func load(from defaults: UserDefaults) -> VisualizationSettings {
        let d = Self.defaults
        func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            let object = defaults.object(forKey: key)
            if let number = object as? NSNumber, isBoolean(number) { return number.boolValue }
            if let text = object as? String {
                switch text.lowercased() {
                case "1", "yes", "true": return true
                case "0", "no", "false": return false
                default: return fallback
                }
            }
            return fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            let object = defaults.object(forKey: key)
            if let number = object as? NSNumber, !isBoolean(number), number.doubleValue.isFinite {
                return number.doubleValue
            }
            if let text = object as? String, let value = Double(text), value.isFinite { return value }
            return fallback
        }
        func string(_ key: String) -> String? { defaults.object(forKey: key) as? String }

        let readouts: Set<VisReadout>
        if let names = defaults.object(forKey: Key.readouts) as? [String] {
            readouts = Set(names.compactMap(VisReadout.init(rawValue:)))
        } else {
            readouts = d.readouts
        }
        return VisualizationSettings(
            autoAdvance: bool(Key.autoAdvance, d.autoAdvance),
            autoAdvanceSeconds: double(Key.autoAdvanceSeconds, d.autoAdvanceSeconds),
            autoAdvanceVaries: bool(Key.autoAdvanceVaries, d.autoAdvanceVaries),
            blendSeconds: double(Key.blendSeconds, d.blendSeconds),
            order: string(Key.order).flatMap(PresetNavigator.Order.init(rawValue:)) ?? d.order,
            locked: bool(Key.locked, d.locked),
            lastPreset: string(Key.lastPreset),
            presetsFolder: string(Key.presetsFolder),
            overlayIdleSeconds: double(Key.overlayIdleSeconds, d.overlayIdleSeconds),
            songTitleOnTrackChange: bool(Key.songTitleOnTrackChange, d.songTitleOnTrackChange),
            readouts: readouts,
            openOnPlay: bool(Key.openOnPlay, d.openOnPlay),
            windowOpen: bool(Key.windowOpen, d.windowOpen),
            changeWithReduceMotion: bool(Key.changeWithReduceMotion, d.changeWithReduceMotion),
            flashNoticeShown: bool(Key.flashNoticeShown, d.flashNoticeShown)
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(autoAdvance, forKey: Key.autoAdvance)
        defaults.set(autoAdvanceSeconds, forKey: Key.autoAdvanceSeconds)
        defaults.set(autoAdvanceVaries, forKey: Key.autoAdvanceVaries)
        defaults.set(blendSeconds, forKey: Key.blendSeconds)
        defaults.set(order.rawValue, forKey: Key.order)
        defaults.set(locked, forKey: Key.locked)
        if let lastPreset { defaults.set(lastPreset, forKey: Key.lastPreset) } else { defaults.removeObject(forKey: Key.lastPreset) }
        if let presetsFolder { defaults.set(presetsFolder, forKey: Key.presetsFolder) } else { defaults.removeObject(forKey: Key.presetsFolder) }
        defaults.set(overlayIdleSeconds, forKey: Key.overlayIdleSeconds)
        defaults.set(songTitleOnTrackChange, forKey: Key.songTitleOnTrackChange)
        defaults.set(VisReadout.allCases.filter(readouts.contains).map(\.rawValue), forKey: Key.readouts)
        defaults.set(openOnPlay, forKey: Key.openOnPlay)
        defaults.set(windowOpen, forKey: Key.windowOpen)
        defaults.set(changeWithReduceMotion, forKey: Key.changeWithReduceMotion)
        defaults.set(flashNoticeShown, forKey: Key.flashNoticeShown)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
