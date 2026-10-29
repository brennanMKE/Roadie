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
    /// In full screen from the window controller (#0237).
    private(set) var isFullScreen = false
    /// The keyboard shortcuts card (F1 / ?, #0239): holds the overlay and suspends auto-advance while open; Esc closes
    /// it before leaving full screen.
    var isHelpOpen = false {
        didSet { if oldValue != isHelpOpen { helpOpenChanged() } }
    }
    /// The song title show running now and how many have started (#0239, `VisualizationModel+Title`).
    var songTitle: SongTitleShow?
    var songTitleShowCount = 0
    /// The display link's measured rate, smoothed, updated once a second (the F5 readout).
    var measuredFPS: Double = 0
    @ObservationIgnored var titleState = TitleState()
    /// The preset list while it's open (L / Presets…, #0240); set through `openList` / `closeList`.
    var presetList: PresetListModel?
    /// The song overlay's and cursor's visibility (#0238); `VisualizationModel+Overlay` drives it.
    var overlay: OverlayVisibility
    /// How many times the overlay has come up this launch: the key hint shows for the first three.
    var overlayShowCount = 0
    /// The overlay's one-shot idle timer and the window's cursor hiding (#0238).
    @ObservationIgnored var overlayTimer: Timer?
    @ObservationIgnored var hideCursor: (() -> Void)?
    /// Whether the pointer is over the picture now, from the window (nil: no window, taken as inside). Read when the
    /// window shows the overlay rather than movement, since the tracking area only sees enters and exits.
    @ObservationIgnored var isPointerInside: (() -> Bool)?
    /// The window, for full screen (#0237).
    @ObservationIgnored weak var fullScreenController: (any FullScreenToggling)?
    /// `close()` while full screen leaves full screen first and closes when that completes.
    @ObservationIgnored private var closesAfterFullScreen = false
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

    enum Suspension: Hashable { case notRendering, menu, list, help }

    /// What the presets folder setting found (Settings › Visualization, #0241).
    enum FolderStatus: Equatable { case none, scanning, notFound, found(Int) }
    /// `.milk` presets from the presets folder, after the last scan.
    private(set) var userPresets: [VisualizationPreset] = []
    private(set) var folderStatus: FolderStatus = .none
    /// Bumped by each `reloadCatalogue`, so an older scan can't overwrite a newer one.
    @ObservationIgnored private var catalogueGeneration = 0
    /// The last playback state other than `.loading`, for open on play.
    @ObservationIgnored private var settledPlayback: NowPlaying.State = .stopped
    /// Debug `-RoadieVisPresetsFolder` in test mode: Choose…'s answer instead of the panel.
    @ObservationIgnored let presetsFolderStandIn: String?

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
        presetsFolderStandIn = configuration.visPresetsFolder
        if let folder = configuration.visPresetsFolder {
            Self.seedPresets(configuration.visSeedPresets ?? 0, in: folder)
            settings.presetsFolder = folder
        }
        self.settings = settings
        overlay = OverlayVisibility(
            idleTimeout: configuration.visOverlayIdle ?? settings.overlayIdleSeconds, now: CACurrentMediaTime())
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
        if settings.presetsFolder != nil { reloadCatalogue() }
    }

    // MARK: Open and close

    func open() {
        guard !isOpen else { return }
        prepareRenderer()
        if settings.presetsFolder != nil { reloadCatalogue() }
        isOpen = true
        hasOpened = true
        setWindowOpenSetting(true)
        startTrackingTitle()
    }

    func close() {
        guard isOpen else { return }
        if isFullScreen, let fullScreenController {
            // A second close during the exit is idempotent (#0245).
            guard !closesAfterFullScreen else { return }
            closesAfterFullScreen = true
            fullScreenController.toggleFullScreen()
            return
        }
        closesAfterFullScreen = false
        isOpen = false
        setVisible(false)
        setWindowOpenSetting(false)
    }

    func toggle() { if isOpen { close() } else { open() } }

    /// From the window controller when a full-screen transition completes; finishes a pending `close()`.
    func setFullScreen(_ fullScreen: Bool) {
        if fullScreen != isFullScreen {
            isFullScreen = fullScreen
            if fullScreen { showOverlay() }
        }
        guard closesAfterFullScreen else { return }
        if fullScreen {
            // AppKit ignored the exit mid-transition (#0245): ask again now the transition is over.
            fullScreenController?.toggleFullScreen()
        } else {
            close()
        }
    }

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
        let usable = PresetCatalog.ordered(PresetCatalog.classics + userPresets).filter { renderer.canLoad($0) }
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

    /// One visualization-window command (design §2.5). Full screen and Escape are #0237's, the list #0240's, the song
    /// title, help and readouts #0239's.
    func perform(_ command: VisCommand) {
        // While the list is open, keys go to it; only Esc and full screen get through (#0240).
        if isListOpen, command != .escape, command != .toggleFullScreen { return }
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
        case .presetList: openList()
        case .showSongTitle: showSongTitleNow()
        case .help: isHelpOpen.toggle()
        case .toggleReadout(let readout): toggleReadout(readout)
        case .toggleFullScreen, .escape:
            handleFullScreenCommand(command)
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
        countFrame(at: now)
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

    // MARK: Settings (#0241)

    /// A Settings › Visualization change: clamped, saved and applied to the running window.
    func updateSettings(_ change: (inout VisualizationSettings) -> Void) {
        let old = settings
        var new = settings
        change(&new)
        new.autoAdvanceSeconds = min(max(new.autoAdvanceSeconds, VisualizationSettings.autoAdvanceRange.lowerBound),
                                     VisualizationSettings.autoAdvanceRange.upperBound)
        new.blendSeconds = min(max(new.blendSeconds, VisualizationSettings.blendRange.lowerBound),
                               VisualizationSettings.blendRange.upperBound)
        new.overlayIdleSeconds = max(0, new.overlayIdleSeconds)
        if new.presetsFolder?.isEmpty == true { new.presetsFolder = nil }
        guard new != old else { return }
        settings = new
        new.save(to: defaults)
        if new.autoAdvancePolicy != clock.policy { clock.policy = new.autoAdvancePolicy }
        if navigator.order != new.order { navigator.order = new.order }
        if navigator.isLocked != new.locked { navigator.isLocked = new.locked }
        if new.presetsFolder != old.presetsFolder { reloadCatalogue() }
        if new.overlayIdleSeconds != old.overlayIdleSeconds { applyOverlayIdleTimeout() }
    }

    /// How long the full-screen overlay and pointer wait before hiding; nil never hides (#0238 reads it).
    var overlayIdleTimeout: TimeInterval? {
        settings.overlayIdleSeconds > 0 ? settings.overlayIdleSeconds : nil
    }

    /// The presets folder setting shows only where the renderer can draw `.milk` presets: Debug's classic renderer
    /// stands in for them; Release after #0243.
    var showsPresetsFolder: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Rescans the presets folder off the main actor, then lists the classics and its presets in the navigator.
    @discardableResult
    func reloadCatalogue() -> Task<Void, Never> {
        catalogueGeneration += 1
        let generation = catalogueGeneration
        guard let path = settings.presetsFolder else {
            applyCatalogue([], status: .none)
            return Task {}
        }
        folderStatus = .scanning
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return Task { [weak self] in
            let found = await Task.detached { () -> [VisualizationPreset]? in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
                else { return nil }
                return PresetCatalog.scan(folder: url, source: .user)
            }.value
            guard let self, generation == self.catalogueGeneration else { return }
            self.applyCatalogue(found ?? [], status: found.map { .found($0.count) } ?? .notFound)
        }
    }

    private func applyCatalogue(_ presets: [VisualizationPreset], status: FolderStatus) {
        userPresets = presets
        if folderStatus != status { folderStatus = status }
        let all = PresetCatalog.ordered(PresetCatalog.classics + presets)
        navigator.replacePresets(renderer.map { renderer in all.filter { renderer.canLoad($0) } } ?? all)
        // The preset showing went with its folder: show what the navigator moved to.
        if renderer != nil, let current = navigator.current, current.id != currentPreset?.id {
            _ = load(current, transition: 0, countsAsChange: false)
        }
    }

    /// From `PlayerModel` on each playback state change: stopped → playing opens the window when Open on Play is on;
    /// resuming from pause and track changes (through `.loading`) don't.
    func playbackStateChanged(to state: NowPlaying.State) {
        guard state != .loading else { return }
        let previous = settledPlayback
        settledPlayback = state
        if state == .playing, previous == .stopped, settings.openOnPlay, !isOpen { open() }
    }

    /// Debug `-RoadieVisSeedPresets N`: N tiny `.milk` files in `folder`, since the sandboxed UI-test runner can't
    /// write them.
    private static func seedPresets(_ count: Int, in folder: String) {
        guard count > 0 else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for index in 1...count {
            let file = url.appending(path: "Seeded Preset \(index).milk")
            try? Data("[preset00]\nfRating=3.0\n".utf8).write(to: file)
        }
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
