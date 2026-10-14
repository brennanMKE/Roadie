import AppKit
import AudioCore
import FolderBackendKit
import Foundation
import LibraryBrowser
import MusicBackendKit
import MusicLibraryKit
import Observation
import PlexBackendKit
import SkinKit
import TrackCache
import os

@MainActor
@Observable
final class PlayerModel {
    private(set) var skin: Skin?
    /// The skin's static layers (background, title strip, clutter bar, transport sprites), rendered once per skin by
    /// `MainWindowRenderer` so the app and `skintool --png` draw the same pixels. Set together with `skin`.
    private(set) var mainWindowBase: MainWindowBase?
    private(set) var skinName: String?
    /// Why there is no skin (a failed skin load); import and skin-load feedback is `notice`.
    private(set) var errorMessage: String?
    /// A transient message that takes over the marquee (and the no-skin placeholder) for a few seconds.
    private(set) var notice: StatusNotice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The sources and the active one. `backend`, `library` and `artwork` below follow its choice; only
    /// `sources.select(_:)` swaps them. The composition in `init` is the one place that names Plex and the folder.
    let sources: LibrarySourceController
    var backend: any MusicBackend { sources.backend }
    /// The Library window's state; connects when the window appears, never at launch.
    var library: LibraryBrowserModel { sources.library }
    /// The thumbnail cache for the active source (rebuilt on a switch: refs only mean something to their backend).
    var artwork: ArtworkCache { sources.artwork }
    /// Moves the Library to the next usable source when the chosen one is not set up or cannot be reached, and
    /// back when it returns. Playback is never touched.
    let fallback: LibraryFallbackController
    let cache: TrackCache
    let cacheSettings: CacheSettingsModel
    /// The local-folder source; Settings › Library chooses and indexes its folder. Shares Plex's "This Mac" output, so both play through the one `Player`.
    let folderBackend: FolderBackend
    let folderSettings: FolderSettingsModel
    /// Still public for the skinned window's time and spectrum bindings and for local files.
    let player: Player
    /// Keeps the current and next tracks pinned in the cache; lives as long as the model.
    private let pinner: CachePinner
    /// Media keys and Control Center; lives as long as the model.
    private let nowPlayingBridge: NowPlayingBridge
    var selectedOutput: OutputDevice.ID = OutputDevice.thisMacID {
        didSet { if selectedOutput != oldValue { observeNowPlaying() } }
    }
    private(set) var nowPlaying: NowPlaying = .idle(on: OutputDevice.thisMacID)
    private var nowPlayingTask: Task<Void, Never>?
    var playbackState: NowPlaying.State { nowPlaying.state }
    var isLoading: Bool { nowPlaying.state == .loading }
    var scale: CGFloat = 2 {
        didSet { visualizer.setScale(scale) }
    }
    /// The main-window spectrum / oscilloscope; ticks only while audio plays.
    let visualizer: VisualizerModel
    /// Replaces the marquee text while set, like Webamp's focus text. Set while a main-window slider is held.
    var marqueeOverride: String?
    /// Which slider the pointer is holding. `position` carries the scrub fraction, which the thumb follows
    /// instead of the clock until release.
    /// `equalizer(band:)` is an equalizer-window slider; band nil is the preamp.
    enum SliderFocus: Equatable { case volume, balance, position(fraction: Double), equalizer(band: Int?) }
    private(set) var sliderFocus: SliderFocus?
    /// The volume and balance sliders' values. Changed by the sliders (sent to the output as commands)
    /// and followed from the output's `NowPlaying.volume` when the slider is not held.
    private(set) var volume: Float = 1
    private(set) var balance: Float = 0
    /// Whether the equalizer window is open: the source of truth for the main window's EQ button, the Window menu and the
    /// window itself (`AppDelegate` follows it). Persisted so the window comes back after a relaunch, like Winamp.
    private(set) var isEQWindowOpen = UserDefaults.standard.bool(forKey: PlayerModel.eqWindowOpenKey)
    /// Whether the playlist editor is open; persisted like the equalizer's (Winamp reopens it at launch).
    private(set) var isPlaylistWindowOpen = UserDefaults.standard.bool(forKey: PlayerModel.playlistWindowOpenKey)
    /// The playlist window's selection, scroll position and size; a view of `player.queue`.
    let playlist: PlaylistModel
    /// Shuffle and repeat live in the local player's queue, so they read as off for other outputs.
    var isShuffled: Bool { selectedOutput == OutputDevice.thisMacID && player.isShuffled }
    var isRepeating: Bool { selectedOutput == OutputDevice.thisMacID && player.repeatMode != .off }
    /// Commands go through one serial stream so a fast slider drag reaches the output in order.
    private let commandStream: AsyncStream<(TransportCommand, OutputDevice.ID)>.Continuation
    /// What the main window marquee shows: a notice, else the slider override, else the now-playing text.
    /// The queue number comes from the local player's queue, which only backs the This Mac output.
    var marqueeText: String {
        if let notice { return notice.text }
        if let marqueeOverride { return marqueeOverride }
        let number = selectedOutput == OutputDevice.thisMacID ? player.queue.currentIndex.map { $0 + 1 } : nil
        return MarqueeText.display(nowPlaying, number: number)
    }

    /// What the no-skin placeholder says: an active notice, else the skin error, else the prompt.
    var placeholderText: String {
        if let notice { return [notice.text, notice.detail].compactMap { $0 }.joined(separator: " \u{2014} ") }
        return errorMessage ?? "Drop a .wsz file here or choose File \u{203A} Open Skin\u{2026}"
    }

    /// Shows `notice` in the marquee (and the no-skin placeholder) until it expires. A new notice
    /// replaces the current one and restarts the clock; Webamp's SET_USER_MESSAGE does the same.
    func post(_ notice: StatusNotice) {
        noticeTask?.cancel()
        self.notice = notice
        noticeTask = Task {
            try? await Task.sleep(until: notice.expiresAt, clock: .continuous)
            guard !Task.isCancelled, self.notice == notice else { return }
            self.notice = nil
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    static let eqWindowOpenKey = "eqWindowOpen"
    static let playlistWindowOpenKey = "playlistWindowOpen"
    static let equalizerKey = "equalizer"
    private static let lastSkinKey = "lastSkinPath"
    private static let timeModeKey = "timeMode"

    /// Elapsed or remaining time in the main window; Winamp keeps it in winamp.ini.
    var timeMode: TimeMode = UserDefaults.standard.string(forKey: PlayerModel.timeModeKey)
        .flatMap(TimeMode.init(rawValue:)) ?? .elapsed

    func toggleTimeMode() {
        timeMode = timeMode == .elapsed ? .remaining : .elapsed
        UserDefaults.standard.set(timeMode.rawValue, forKey: Self.timeModeKey)
    }

    /// What the main window's time, kbps/kHz and mono/stereo area shows. On This Mac the position, track
    /// metadata and opened file format come from the local player (read every 100 ms tick); other
    /// outputs only report the `NowPlaying` snapshot, which has no bitrate or format.
    var mainWindowStatus: MainWindowStatus {
        let transport: Transport = switch nowPlaying.state {
        case .stopped: .stopped
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        }
        let isLocal = selectedOutput == OutputDevice.thisMacID
        let track = isLocal ? player.queue.current : nil
        return MainWindowStatus(
            transport: transport, timeMode: timeMode,
            elapsed: isLocal ? player.currentTime : nowPlaying.elapsed(at: Date()),
            duration: nowPlaying.duration ?? track?.duration ?? 0,
            bitrateKbps: track?.bitrate,
            sampleRate: (isLocal ? player.currentFormat?.sampleRate : nil) ?? track?.sampleRate,
            channels: (isLocal ? player.currentFormat?.channels : nil) ?? track?.channels)
    }

    init() {
        let stack = PlexPlaybackStack.standard()
        cache = stack.cache
        player = stack.player
        playlist = PlaylistModel(player: stack.player)
        visualizer = VisualizerModel(player: stack.player, colors: VisRenderer.defaultColors)
        pinner = stack.pinner
        cacheSettings = CacheSettingsModel(cache: stack.cache)
        folderBackend = FolderBackend(settings: FolderBackend.settingsProvider(), output: stack.output)
        folderSettings = FolderSettingsModel(backend: folderBackend)
        sources = LibrarySourceController(
            sources: [
                LibrarySource(backend: stack.backend, isConfigured: { PlexBackend.isConfigured() }),
                LibrarySource(
                    backend: folderBackend, isConfigured: { FolderBackend.storedFolder() != nil },
                    probe: SourceProbes.checking { try FolderBackend.checkReachable() }),
            ],
            defaultSourceID: stack.backend.sourceID)
        fallback = LibraryFallbackController(sources: sources)
        let cache = stack.cache
        Task {
            do { try await cache.prepare() } catch {
                Logger(subsystem: "com.brennanmke.SkinAmp", category: "TrackCache")
                    .error("could not prepare the cache: \(error.localizedDescription, privacy: .public)")
            }
        }
        let (commands, continuation) = AsyncStream.makeStream(of: (TransportCommand, OutputDevice.ID).self)
        commandStream = continuation
        nowPlayingBridge = NowPlayingBridge(player: stack.player)
        nowPlayingBridge.install()
        stack.player.addEventObserver { [weak self] event in
            guard case .failed(let failure) = event else { return }
            self?.showPlaybackFailure(failure)
        }
        volume = stack.player.volume
        balance = stack.player.balance
        // Restore the equalizer before anything plays; the setter reaches the live graph once it exists.
        if let data = UserDefaults.standard.data(forKey: Self.equalizerKey),
            let saved = try? JSONDecoder().decode(EQState.self, from: data)
        {
            stack.player.eq = saved
        }
        Task { [weak self] in
            for await (command, output) in commands {
                guard let self else { return }
                do { try await self.backend.transport(command, on: output) } catch {
                    self.showBackendFailure(error)
                }
            }
        }
        playlist.isLocal = { [weak self] in self?.selectedOutput == OutputDevice.thisMacID }
        visualizer.setScale(scale)
        visualizer.start()
        observeNowPlaying()
        if let path = UserDefaults.standard.string(forKey: Self.lastSkinKey) {
            loadSkin(from: URL(filePath: path))
        }
        fallback.onNotice = { [weak self] in self?.post(StatusNotice(text: $0.text, detail: $0.detail)) }
        fallback.start()
        // The model lives as long as the app, so these observers are never removed.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fallback.settingsChanged() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fallback.retryNow() } }
    }

    /// Follows the selected output's now-playing stream. Never connects: the stream for This Mac
    /// works without a server.
    private func observeNowPlaying() {
        nowPlayingTask?.cancel()
        let sources = sources
        let output = selectedOutput
        nowPlaying = .idle(on: output)
        nowPlayingTask = Task { [weak self] in
            for await snapshot in sources.nowPlaying(on: output) {
                guard !Task.isCancelled else { return }
                self?.nowPlaying = snapshot
                if let volume = snapshot.volume, self?.sliderFocus != .volume { self?.volume = volume }
            }
        }
    }

    func loadSkin(from url: URL) {
        Task {
            let result = await Task.detached {
                Result {
                    let skin = try SkinParser.parse(url: url)
                    return (skin, MainWindowBase(skin: skin))
                }
            }.value
            switch result {
            case .success(let (skin, base)):
                self.skin = skin
                mainWindowBase = base
                visualizer.setColors(skin.visColors)
                skinName = url.deletingPathExtension().lastPathComponent
                errorMessage = nil
                UserDefaults.standard.set(url.path, forKey: Self.lastSkinKey)
                for warning in skin.warnings { print("[\(url.lastPathComponent)] \(warning)") }
            case .failure(let error):
                errorMessage = "\(url.lastPathComponent): \(error)"
                post(.skinFailed(url.deletingPathExtension().lastPathComponent))
            }
        }
    }

    func play() { send(.play) }
    func pause() { send(.togglePlayPause) }
    func stop() { send(.stop) }
    func previous() { send(.previous) }
    func next() { send(.next) }

    private func send(_ command: TransportCommand) {
        commandStream.yield((command, selectedOutput))
    }

    // MARK: Main-window sliders and toggles

    /// 0...1 through the output; shows "Volume: 57%" in the marquee while held.
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        sliderFocus = .volume
        marqueeOverride = MarqueeText.volume(clamped)
        send(.setVolume(clamped))
    }

    /// -1...1, snapped to centre inside 25 % like Winamp.
    func setBalance(_ value: Float) {
        let snapped = MainSliders.snappedBalance(min(max(value, -1), 1))
        balance = snapped
        sliderFocus = .balance
        marqueeOverride = MarqueeText.balance(snapped)
        send(.setBalance(snapped))
    }

    /// Marks `focus` as held and shows `text` in the marquee until `endSliderDrag()`. The equalizer window's
    /// sliders (`PlayerModel+Equalizer.swift`) go through this, since `sliderFocus` is settable only here.
    func holdSlider(_ focus: SliderFocus, marquee text: String) {
        sliderFocus = focus
        marqueeOverride = text
    }

    /// Volume and balance are applied live, so releasing only clears the marquee text.
    func endSliderDrag() {
        sliderFocus = nil
        marqueeOverride = nil
    }

    /// 0...1, or nil when nothing is seekable (stopped, loading, unknown duration); the thumb is hidden then.
    var positionFraction: Double? {
        let status = mainWindowStatus
        guard status.transport == .playing || status.transport == .paused, status.duration > 0 else { return nil }
        return min(max(status.elapsed / status.duration, 0), 1)
    }

    /// While the position thumb is dragged: follows the pointer and shows "Seek to:" without seeking.
    func scrub(toFraction fraction: Double) {
        let duration = mainWindowStatus.duration
        guard duration > 0 else { return }
        sliderFocus = .position(fraction: fraction)
        marqueeOverride = MarqueeText.seek(fraction: fraction, duration: duration)
    }

    /// Drag release: seeks once. No-op unless a track with a known length is playing or paused.
    func seek(toFraction fraction: Double) {
        defer { endSliderDrag() }
        guard positionFraction != nil else { return }
        send(.seek(min(max(fraction, 0), 1) * mainWindowStatus.duration))
    }

    func toggleShuffle() { send(.setShuffle(!isShuffled)) }
    func toggleRepeat() { send(.setRepeat(player.repeatMode.toggled != .off)) }
    func toggleEQWindow() { setEQWindowOpen(!isEQWindowOpen) }

    /// Also called by the equalizer window when it closes itself.
    func setEQWindowOpen(_ open: Bool) {
        guard open != isEQWindowOpen else { return }
        isEQWindowOpen = open
        UserDefaults.standard.set(open, forKey: Self.eqWindowOpenKey)
    }

    func togglePlaylistWindow() { setPlaylistWindowOpen(!isPlaylistWindowOpen) }

    /// Also called by the playlist window when it closes itself.
    func setPlaylistWindowOpen(_ open: Bool) {
        guard open != isPlaylistWindowOpen else { return }
        isPlaylistWindowOpen = open
        UserDefaults.standard.set(open, forKey: Self.playlistWindowOpenKey)
    }

    private static let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "Playback")

    /// A track the local player could not play: the marquee says which (or how many), Console says why.
    private func showPlaybackFailure(_ failure: PlaybackFailure) {
        Self.log.error("could not play \(failure.track?.title ?? "-", privacy: .public): \(failure.message, privacy: .public)")
        post(.playbackFailed(failure))
    }

    /// A backend refused to play or to take a transport command. `MusicBackendError` describes itself for the
    /// user (no URL, token or header by contract); anything else shows a generic text with its description as detail.
    private func showBackendFailure(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        let text = (error as? MusicBackendError)?.errorDescription ?? "Could not play"
        Self.log.error("backend: \(error.localizedDescription, privacy: .public)")
        post(StatusNotice(text: text, detail: error is MusicBackendError ? nil : error.localizedDescription))
    }

    /// The browser's entry point. nil (nothing selected) is a no-op. Errors such as `.notConnected`,
    /// `.notFound` and "no file on the server" land in the marquee notice, as transport errors do.
    func playFromLibrary(_ request: PlayRequest?) {
        guard let request else { return }
        let mode: String
        switch request.mode {
        case .replace: mode = "replace"
        case .append: mode = "append"
        }
        Self.log.info("play from library: \(request.items.count, privacy: .public) item(s), \(mode, privacy: .public)")
        let backend = backend
        let sourceID = backend.sourceID
        let output = selectedOutput
        Task {
            do { try await backend.play(request.items, on: output, mode: request.mode) } catch {
                fallback.report(error, from: sourceID)
                showBackendFailure(error)
            }
        }
    }

    /// Winamp's eject button opens the file dialog.
    func eject() { openFiles(replace: true) }

    /// Shows the open panel for audio files, folders and skins. Open replaces the queue and plays;
    /// Add appends. A chosen `.wsz` loads as the skin. The app is not sandboxed, so the returned
    /// URLs are directly readable.
    func openFiles(replace: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = LocalTrackLoader.audioTypes + [.wsz]
        panel.message = "Choose audio files, folders or a skin"
        panel.prompt = replace ? "Open" : "Add"
        Task {
            guard await panel.begin() == .OK else { return }
            open(panel.urls, replace: replace)
        }
    }

    /// Shows the open panel for skins only.
    func openSkin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.wsz, .zip]
        panel.message = "Choose a skin"
        panel.prompt = "Open"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            loadSkin(from: url)
        }
    }

    /// Routes chosen or dropped URLs: the first `.wsz` loads as the skin (any others are ignored)
    /// and everything else is imported as audio.
    @discardableResult
    func open(_ urls: [URL], replace: Bool) -> Bool {
        let isSkin = { (url: URL) in url.pathExtension.lowercased() == "wsz" }
        let skin = urls.first(where: isSkin)
        let others = urls.filter { !isSkin($0) }
        if let skin { loadSkin(from: skin) }
        importLocalFiles(others, replace: replace)
        return skin != nil || !others.isEmpty
    }

    /// Loads files and folders off the main actor, then queues them. Replacing clears the queue
    /// and starts the first new track; appending only starts playback on an idle, empty player.
    func importLocalFiles(_ urls: [URL], replace: Bool) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await LocalTrackLoader.load(urls)
            if let skipped = StatusNotice.skipped(result) { post(skipped) } else { clearNotice() }
            guard !result.tracks.isEmpty else { return }
            let wasIdle = player.state == .stopped && player.queue.tracks.isEmpty
            if replace { player.clearQueue() }
            let start = player.queue.tracks.count
            player.enqueue(result.tracks)
            if replace || wasIdle { player.play(at: start) }
        }
    }
}

/// The main window's static layers for both title-bar states, as `MainWindowRenderer.renderBase` draws them.
struct MainWindowBase: @unchecked Sendable {
    let focused: CGImage
    let unfocused: CGImage

    init(skin: Skin) {
        focused = MainWindowRenderer.renderBase(skin: skin, focused: true)
        unfocused = MainWindowRenderer.renderBase(skin: skin, focused: false)
    }
}
