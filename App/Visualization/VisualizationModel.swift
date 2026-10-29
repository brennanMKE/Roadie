import AppKit
import AudioCore
import Foundation
import MusicBackendKit
import Observation
import QuartzCore
import SkinKit
import VisualizationKit
import os

/// The visualization window's state and render loop (design §3.4): which preset shows, whether the window is open and
/// on screen, the stereo feed and the renderer. `VisualizationWindowController` owns the window and calls `tick` from
/// its display link; `AppDelegate` shows or closes the window to follow `isOpen`.
@MainActor
@Observable
final class VisualizationModel {
    /// Where the music the window would show is playing (design §4.4).
    enum AudioSource: Equatable {
        case local
        case remote(String)
        case none

        var probeName: String {
            switch self {
            case .local: "local"
            case .remote: "remote"
            case .none: "none"
            }
        }
    }

    private static let log = Logger(subsystem: "co.sstools.roadie", category: "Visualization")

    private(set) var isOpen = false
    /// Open and on screen (not miniaturized, not occluded, app not hidden): the display link runs and the stereo feed is on.
    private(set) var isRendering = false
    private(set) var currentPreset: VisualizationPreset?
    /// Every successful preset change since launch (the probe's `presetChanges`).
    private(set) var presetChanges = 0
    /// Set on the first `open()`: the probe reports nothing before.
    private(set) var hasOpened = false
    private(set) var settings: VisualizationSettings
    private(set) var navigator: PresetNavigator
    /// Low Power Mode or a serious thermal state: 30 fps whatever plays.
    private(set) var isConstrained = false
    /// The last preset change's transition (`"blend 1.7"`, `"blend 2.7"`, `"cut"`), for the probe.
    private(set) var lastTransition: String?
    /// When the next automatic preset change is due (design §2.4).
    @ObservationIgnored private(set) var clock: AutoAdvanceClock
    /// The model's time source; tests replace it with a manual clock. Same base as the display link's timestamp.
    @ObservationIgnored var currentTime: () -> TimeInterval = { CACurrentMediaTime() }
    /// A key change's preset, for the window's toast. Automatic changes don't call it.
    @ObservationIgnored var onKeyChange: ((VisualizationPreset) -> Void)?
    /// Where transport and volume keys go; tests replace it to observe them.
    @ObservationIgnored var performHotkey: ((WinampHotkey) -> Void)?

    /// Built lazily on first open (`makeRenderer`), so a launch that never opens the window builds nothing.
    @ObservationIgnored private(set) var renderer: (any VisualizationRenderer)?
    /// Replaced by tests with a double before the first open.
    @ObservationIgnored var makeRenderer: @MainActor () -> any VisualizationRenderer
    /// The player model, for the audio source; set by `PlayerModel` after its init.
    @ObservationIgnored weak var owner: PlayerModel?

    @ObservationIgnored private let analyzer: AnalyzerTap
    @ObservationIgnored private let reader: StereoFeedReader
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var colors: [SkinKit.RGBColor] = VisRenderer.defaultColors
    @ObservationIgnored private var renderTime: TimeInterval = 0
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Why auto-advance is paused (not rendering, the right-click menu open); the clock runs only when empty.
    @ObservationIgnored private var suspensions: Set<Suspension> = []

    enum Suspension: Hashable { case notRendering, menu }

    init(analyzer: AnalyzerTap, configuration: RoadieConfiguration) {
        self.analyzer = analyzer
        reader = StereoFeedReader(tap: analyzer)
        defaults = configuration.defaults
        var settings = VisualizationSettings.load(from: configuration.defaults)
        if let seconds = configuration.visAutoAdvance {
            // Debug hook: not clamped and not saved, so a UI test sees a change in seconds.
            settings.autoAdvance = true
            settings.autoAdvanceSeconds = seconds
            settings.autoAdvanceVaries = false
        }
        self.settings = settings
        let seed = configuration.visSeed ?? UInt64.random(in: .min ... .max)
        clock = AutoAdvanceClock(policy: settings.autoAdvancePolicy, seed: seed)
        let classics = PresetCatalog.ordered(PresetCatalog.classics)
        let navigator = PresetNavigator(
            presets: classics, order: settings.order, isLocked: settings.locked, startingAt: settings.lastPreset,
            seed: seed)
        self.navigator = navigator
        makeRenderer = { VisualizationRendererFactory.make(configuration: configuration, colors: VisRenderer.defaultColors) }
        currentPreset = navigator.current
        suspensions = [.notRendering]
        updateConstrained()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateConstrained() }
            })
        }
        clock.suspend(at: currentTime())
    }

    // MARK: Open and close

    func open() {
        guard !isOpen else { return }
        prepareRenderer()
        isOpen = true
        hasOpened = true
        setWindowOpenSetting(true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        setVisible(false)
        setWindowOpenSetting(false)
    }

    func toggle() { if isOpen { close() } else { open() } }

    /// From the window controller: on screen, not miniaturized, `occlusionState.contains(.visible)`, app not hidden.
    func setVisible(_ visible: Bool) {
        let rendering = isOpen && visible
        guard rendering != isRendering || analyzer.isStereoEnabled != rendering else { return }
        if rendering, !isRendering { reader.reset() }
        isRendering = rendering
        lastTick = nil
        analyzer.setStereoEnabled(rendering)
        setSuspended(.notRendering, !rendering)
    }

    /// Pauses or resumes auto-advance for `reason`; the clock runs only while nothing holds it.
    func setSuspended(_ reason: Suspension, _ suspended: Bool) {
        if suspended { suspensions.insert(reason) } else { suspensions.remove(reason) }
        if suspensions.isEmpty { clock.resume(at: currentTime()) } else { clock.suspend(at: currentTime()) }
    }

    /// The renderer, built on first use, with the navigator's list filtered to what it can load and the current preset
    /// loaded (falling back past presets that fail).
    @discardableResult
    func prepareRenderer() -> any VisualizationRenderer {
        if let renderer { return renderer }
        let renderer = makeRenderer()
        renderer.setColors(colors)
        self.renderer = renderer
        let usable = PresetCatalog.ordered(PresetCatalog.classics).filter { renderer.canLoad($0) }
        navigator.replacePresets(usable)
        if let lastPreset = settings.lastPreset, navigator.current?.id != lastPreset { _ = navigator.select(id: lastPreset) }
        var candidate = navigator.current
        while let preset = candidate {
            if load(preset, transition: 0, countsAsChange: false) { break }
            candidate = navigator.usable.first
        }
        return renderer
    }

    // MARK: Presets

    /// Loads `preset` into the renderer. On a throw the preset is marked failed and the previous one stays.
    @discardableResult
    func load(_ preset: VisualizationPreset, transition: TimeInterval) -> Bool {
        load(preset, transition: transition, countsAsChange: true)
    }

    private func load(_ preset: VisualizationPreset, transition: TimeInterval, countsAsChange: Bool) -> Bool {
        let renderer = renderer ?? prepareRenderer()
        do {
            try renderer.load(preset, transition: transition)
        } catch {
            Self.log.error("preset \(preset.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            navigator.markFailed(id: preset.id)
            // Keep the navigator on what's showing.
            if let current = currentPreset, current.id != preset.id, navigator.current?.id != current.id {
                _ = navigator.select(id: current.id)
            }
            return false
        }
        if navigator.current?.id != preset.id { _ = navigator.select(id: preset.id) }
        currentPreset = preset
        if countsAsChange {
            presetChanges += 1
            lastTransition = transition > 0 ? String(format: "blend %.1f", transition) : "cut"
        }
        clock.restart(at: currentTime())
        settings.lastPreset = preset.id
        defaults.set(preset.id, forKey: VisualizationSettings.Key.lastPreset)
        return true
    }

    // MARK: Commands

    /// One visualization-window command (design §2.5). Full screen and Escape are #0237's; the list, song title,
    /// help and readouts are later issues'.
    func perform(_ command: VisCommand) {
        switch command {
        case .nextPreset: changeByKey(transition: VisualizationSettings.keyBlend) { $0.next() }
        case .previousPreset: changeByKey(transition: VisualizationSettings.keyBlend) { $0.previous() }
        case .hardCut: changeByKey(transition: 0) { $0.next() }
        case .toggleOrder:
            navigator.order = navigator.order == .random ? .sequential : .random
            settings.order = navigator.order
            defaults.set(navigator.order.rawValue, forKey: VisualizationSettings.Key.order)
        case .toggleLock:
            navigator.isLocked.toggle()
            settings.locked = navigator.isLocked
            defaults.set(navigator.isLocked, forKey: VisualizationSettings.Key.locked)
        case .transport(let transport): hotkey(Self.hotkey(for: transport))
        case .presetList, .showSongTitle, .help, .toggleReadout:
            break  // #0239, #0240
        case .toggleFullScreen, .escape:
            break  // #0237
        }
    }

    static func hotkey(for transport: VisTransport) -> WinampHotkey {
        switch transport {
        case .previous: .previous
        case .play: .play
        case .pause: .pause
        case .stop: .stop
        case .next: .next
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        }
    }

    private func hotkey(_ hotkey: WinampHotkey) {
        if let performHotkey { performHotkey(hotkey) } else { owner?.perform(hotkey) }
    }

    /// A key change: `move` the navigator, load what it lands on, toast its name. With one usable preset left after the
    /// current one failed, that one is selected (the navigator moves only between two or more).
    private func changeByKey(transition: TimeInterval, _ move: (inout PresetNavigator) -> VisualizationPreset?) {
        var target = move(&navigator)
        if target == nil, navigator.usable.count == 1, let only = navigator.usable.first, only.id != currentPreset?.id {
            target = navigator.select(id: only.id)
        }
        guard let target, load(target, transition: transition) else { return }
        onKeyChange?(target)
    }

    var windowTitle: String {
        currentPreset.map { "Visualization — \($0.name)" } ?? "Visualization"
    }

    func setColors(_ colors: [SkinKit.RGBColor]) {
        self.colors = colors
        renderer?.setColors(colors)
    }

    // MARK: Render loop

    /// One display-link tick: the stereo feed since the last tick goes to the renderer, then it draws. Time
    /// accumulates only while rendering.
    func tick(now: TimeInterval) {
        guard isRendering, let renderer else { return }
        let dt = max(lastTick.map { now - $0 } ?? 1.0 / 60, 0)
        lastTick = now
        renderTime += dt
        if clock.isDue(at: now) {
            if let preset = navigator.advanceAutomatically() { load(preset, transition: settings.blendSeconds) }
            clock.restart(at: now)
        }
        if let audio = reader.read(elapsed: dt) {
            renderer.feed(audio.samples, channels: 2, sampleRate: audio.sampleRate)
        }
        renderer.draw(at: renderTime)
    }

    /// 60 while This Mac plays, else 30; 30 under Low Power Mode or a serious thermal state.
    var preferredFrameRate: Float {
        guard !isConstrained, audioSource == .local, owner?.playbackState == .playing else { return 30 }
        return 60
    }

    var audioSource: AudioSource {
        guard let owner else { return .none }
        let name = owner.outputPicker.devices.first { $0.id == owner.selectedOutput }?.name
        return Self.audioSource(
            selectedOutput: owner.selectedOutput, thisMacID: OutputDevice.thisMacID, outputName: name,
            state: owner.playbackState)
    }

    /// Remote when the output isn't This Mac (no PCM reaches the tap), `.none` when stopped (design §4.4).
    static func audioSource(
        selectedOutput: OutputDevice.ID, thisMacID: OutputDevice.ID, outputName: String?, state: NowPlaying.State
    ) -> AudioSource {
        if state == .stopped { return .none }
        if selectedOutput != thisMacID { return .remote(outputName ?? selectedOutput.rawValue) }
        return .local
    }

    // MARK: Private

    private func setWindowOpenSetting(_ open: Bool) {
        settings.windowOpen = open
        defaults.set(open, forKey: VisualizationSettings.Key.windowOpen)
    }

    private func updateConstrained() {
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if constrained != isConstrained { isConstrained = constrained }
    }
}
