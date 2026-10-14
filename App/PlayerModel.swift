import AppKit
import AudioCore
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
    private(set) var skinName: String?
    private(set) var errorMessage: String?
    /// The app only talks to this; the composition below is the one place that names Plex.
    let backend: any MusicBackend
    /// The Library window's state; connects when the window appears, never at launch.
    let library: LibraryBrowserModel
    /// The one thumbnail cache for the process. Refs only mean something to `backend`, so a source switch must `clear()` it.
    let artwork: ArtworkCache
    let cache: TrackCache
    let cacheSettings: CacheSettingsModel
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
    enum SliderFocus: Equatable { case volume, balance, position(fraction: Double) }
    private(set) var sliderFocus: SliderFocus?
    /// The volume and balance sliders' values. Changed by the sliders (sent to the output as commands)
    /// and followed from the output's `NowPlaying.volume` when the slider is not held.
    private(set) var volume: Float = 1
    private(set) var balance: Float = 0
    /// EQ and playlist toggles only record state until M5 adds the windows; M5 swaps in their visibility.
    private(set) var isEQWindowOpen = false
    private(set) var isPlaylistWindowOpen = false
    /// Shuffle and repeat live in the local player's queue, so they read as off for other outputs.
    var isShuffled: Bool { selectedOutput == OutputDevice.thisMacID && player.isShuffled }
    var isRepeating: Bool { selectedOutput == OutputDevice.thisMacID && player.repeatMode != .off }
    /// Commands go through one serial stream so a fast slider drag reaches the output in order.
    private let commandStream: AsyncStream<(TransportCommand, OutputDevice.ID)>.Continuation
    /// What the main window marquee shows: the override, else the now-playing text. The queue number comes
    /// from the local player's queue, which only backs the This Mac output.
    var marqueeText: String {
        if let marqueeOverride { return marqueeOverride }
        let number = selectedOutput == OutputDevice.thisMacID ? player.queue.currentIndex.map { $0 + 1 } : nil
        return MarqueeText.display(nowPlaying, number: number)
    }

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
        backend = stack.backend
        library = LibraryBrowserModel(backend: stack.backend)
        artwork = ArtworkCache(backend: stack.backend)
        cache = stack.cache
        player = stack.player
        visualizer = VisualizerModel(player: stack.player, colors: VisRenderer.defaultColors)
        pinner = stack.pinner
        cacheSettings = CacheSettingsModel(cache: stack.cache)
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
        volume = stack.player.volume
        balance = stack.player.balance
        let transportBackend = stack.backend
        Task { [weak self] in
            for await (command, output) in commands {
                do { try await transportBackend.transport(command, on: output) } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
        visualizer.setScale(scale)
        visualizer.start()
        observeNowPlaying()
        if let path = UserDefaults.standard.string(forKey: Self.lastSkinKey) {
            loadSkin(from: URL(filePath: path))
        }
    }

    /// Follows the selected output's now-playing stream. Never connects: the stream for This Mac
    /// works without a server.
    private func observeNowPlaying() {
        nowPlayingTask?.cancel()
        let backend = backend
        let output = selectedOutput
        nowPlaying = .idle(on: output)
        nowPlayingTask = Task { [weak self] in
            for await snapshot in await backend.nowPlaying(on: output) {
                guard !Task.isCancelled else { return }
                self?.nowPlaying = snapshot
                if let volume = snapshot.volume, self?.sliderFocus != .volume { self?.volume = volume }
            }
        }
    }

    func loadSkin(from url: URL) {
        Task {
            let result = await Task.detached { Result { try SkinParser.parse(url: url) } }.value
            switch result {
            case .success(let skin):
                self.skin = skin
                visualizer.setColors(skin.visColors)
                skinName = url.deletingPathExtension().lastPathComponent
                errorMessage = nil
                UserDefaults.standard.set(url.path, forKey: Self.lastSkinKey)
                for warning in skin.warnings { print("[\(url.lastPathComponent)] \(warning)") }
            case .failure(let error):
                errorMessage = "\(url.lastPathComponent): \(error)"
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
    func toggleEQWindow() { isEQWindowOpen.toggle() }
    func togglePlaylistWindow() { isPlaylistWindowOpen.toggle() }

    private static let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "Playback")

    /// The browser's entry point. nil (nothing selected) is a no-op. Errors such as `.notConnected`,
    /// `.notFound` and "no file on the server" land in `errorMessage`, as transport errors do.
    func playFromLibrary(_ request: PlayRequest?) {
        guard let request else { return }
        let mode: String
        switch request.mode {
        case .replace: mode = "replace"
        case .append: mode = "append"
        }
        Self.log.info("play from library: \(request.items.count, privacy: .public) item(s), \(mode, privacy: .public)")
        let backend = backend
        let output = selectedOutput
        Task {
            do { try await backend.play(request.items, on: output, mode: request.mode) } catch {
                errorMessage = error.localizedDescription
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
            guard !result.tracks.isEmpty else {
                if !result.skipped.isEmpty {
                    errorMessage = "Skipped \(result.skipped.count) file(s) \u{2014} see Console"
                }
                return
            }
            let wasIdle = player.state == .stopped && player.queue.tracks.isEmpty
            if replace { player.clearQueue() }
            let start = player.queue.tracks.count
            player.enqueue(result.tracks)
            if replace || wasIdle { player.play(at: start) }
        }
    }
}
