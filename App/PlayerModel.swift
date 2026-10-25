import AppKit
import AudioCore
import FolderBackendKit
import Foundation
import LibraryBrowser
import LocalPlayback
import MusicAssistantKit
import MusicBackendKit
import MusicLibraryKit
import Observation
import SwiftUI
import SkinBrowser
import SkinKit
import SkinLibrary
import SkinMuseum
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
    /// Captured from `PlayerView` so the skinned menu can open SwiftUI windows (#0185).
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    /// Check for Updates… in the skinned main menu (#0158). The app injects these from `Updater`, so the model and
    /// SkinKit stay free of Sparkle; nil leaves the item disabled.
    @ObservationIgnored var updateActions: (canCheck: () -> Bool, check: () -> Void)?
    /// The sources and the active one. `backend`, `library` and `artwork` below follow its choice; only
    /// `sources.select(_:)` swaps them. The composition in `init` is the one place that names Music Assistant and the folder.
    let sources: LibrarySourceController
    var backend: any MusicBackend { sources.backend }
    /// The Library window's state. Music Assistant also connects at launch when a verified server exists (#0121).
    var library: LibraryBrowserModel { sources.library }
    /// The thumbnail cache for the active source (rebuilt on a switch: refs only mean something to their backend).
    var artwork: ArtworkCache { sources.artwork }
    /// Moves the Library to the next usable source when the chosen one is not set up or cannot be reached, and
    /// back when it returns. Playback is never touched.
    let fallback: LibraryFallbackController
    /// The skins folder and its SQLite index (Settings › Skins). Opens nothing until a folder is chosen.
    let skinLibrary = SkinLibraryModel()
    /// The tab the Skins window shows the next time it appears or is brought forward (#0169); consumed by the window.
    var pendingSkinsSource: SkinsSource?
    /// Main-window thumbnails keyed by content hash, rendered lazily on request (#0034). Does no I/O until the first request.
    let skinThumbnails = SkinThumbnailCache(directory: SkinThumbnailCache.defaultDirectory())
    /// The Skins window and menu (#0035). Lazy because its closures name `self`; it does no I/O until used.
    @ObservationIgnored private(set) lazy var skinBrowser = SkinBrowserModel(
        index: { [skinLibrary] in try await skinLibrary.openStoreIfNeeded() },
        folder: { [skinLibrary] in skinLibrary.folderURL },
        thumbnails: SkinThumbnailAdapter(cache: skinThumbnails),
        applySkin: { [weak self] in self?.loadSkin(from: $0) })
    /// The Museum tab of the Skins window (#0126). Lazy, and it makes no request until the tab appears.
    @ObservationIgnored private(set) lazy var museumBrowser: MuseumBrowserModel = {
        self.museumBrowserCreated = true
        let transport = URLSessionMuseumTransport()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let userAgent = MuseumUserAgent.make(version: version)
        let caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "co.sstools.roadie/Museum", directoryHint: .isDirectory)
        let results = MuseumResultCache(directory: caches.appending(path: "Results", directoryHint: .isDirectory))
        return MuseumBrowserModel(
            client: MuseumClient(transport: transport, userAgent: userAgent, resultCache: results),
            downloader: MuseumDownloader(transport: transport, userAgent: userAgent),
            screenshots: MuseumScreenshotCache(
                directory: caches.appending(path: "Screenshots", directoryHint: .isDirectory),
                transport: transport, userAgent: userAgent),
            folder: { [skinLibrary] in skinLibrary.folderURL },
            lookup: { [skinLibrary] in try await skinLibrary.openStoreIfNeeded() },
            indexAdded: { [weak self] url in
                guard let self else { return }
                await skinLibrary.addDownloaded(url)
                skinBrowser.indexDidChange()
            },
            applySkin: { [weak self] in self?.loadSkin(from: $0) },
            showsNSFW: { UserDefaults.standard.bool(forKey: Self.museumShowsNSFWKey) },
            setShowsNSFW: { UserDefaults.standard.set($0, forKey: Self.museumShowsNSFWKey) })
    }()
    @ObservationIgnored private var museumBrowserCreated = false
    static let museumShowsNSFWKey = "museumShowsNSFW"
    @ObservationIgnored private var skinLoadGeneration = 0
    /// The local-folder source; Settings › Library chooses and indexes its folder. Owns the "This Mac" output (`LocalPlaybackStack`), which every local track plays through.
    let folderBackend: FolderBackend
    let folderSettings: FolderSettingsModel
    /// The Music Assistant source (#0063): the backend, the server Settings chose, and Settings › Music Assistant's model.
    let musicAssistant: MusicAssistantBackend
    let musicAssistantActive: MusicAssistantActiveServer
    let musicAssistantSettings: MusicAssistantSettingsModel
    /// Picks the reachable server automatically (#0075).
    let musicAssistantSelection: MusicAssistantSelectionController
    /// #0104: finds servers on the current network; runs only while Settings › Music Assistant or the Library asks.
    let musicAssistantDiscovery: MusicAssistantDiscoveryModel
    @ObservationIgnored private var maDropTask: Task<Void, Never>?
    /// Still public for the skinned window's time and spectrum bindings and for local files.
    let player: Player
    /// Saves the queue to Application Support a moment after each change and on quit (#0071); lives as long as the model.
    private let queueAutosaver: QueueAutosaver
    /// Media keys and Control Center; lives as long as the model.
    private let nowPlayingBridge: NowPlayingBridge
    /// Sends media-key and Control Center commands to the player (This Mac) or to the selected speaker (#0064).
    @ObservationIgnored private var nowPlayingRouting: NowPlayingRouting?
    /// Transport and now-playing follow the selected output, not the Library's source (#0064).
    let router: PlaybackRouter
    /// What feeds This Mac: the local queue or Music Assistant over Sendspin (#0109). Set only through `setThisMacFeed`.
    let feedState: ThisMacFeedState
    /// Starts and stops the Sendspin session that makes This Mac a Music Assistant player (#0109).
    let sendspinController: SendspinController
    var thisMacFeed: ThisMacFeed { feedState.feed }
    /// Whether the local queue drives what the windows show: This Mac is the output and AudioCore's queue feeds it.
    /// `selectedOutput == thisMacID` alone still means "the Mac's own audio" (the local-files gate, balance).
    var playsLocalQueue: Bool { selectedOutput == OutputDevice.thisMacID && thisMacFeed == .local }
    /// The Library's Output menu.
    let outputPicker: OutputPickerModel
    /// The artwork shown in Control Center for a remote output, and the fetch for the current ref.
    @ObservationIgnored private var externalArtwork: (ref: ArtworkRef, data: Data?)?
    @ObservationIgnored private var externalArtworkTask: Task<Void, Never>?
    var selectedOutput: OutputDevice.ID = OutputDevice.thisMacID {
        didSet {
            guard selectedOutput != oldValue else { return }
            // Any other write (adoption, fallback, a plain pick) leaves the leader alone in the selection (#0118).
            if outputSelection.leader != selectedOutput { outputSelection = OutputSelection(leader: selectedOutput) }
            previousTarget = oldValue
            observeNowPlaying()
        }
    }
    /// The Output popover's checked outputs (#0118). Its leader is always `selectedOutput`.
    var outputSelection = OutputSelection.thisMac
    @ObservationIgnored private var outputSelectionTask: Task<Void, Never>?
    /// The output targeted before the current one: what an exclusive start stops (#0121).
    @ObservationIgnored var previousTarget: OutputDevice.ID?
    /// Every Music Assistant player's playback, from `playbackActivity()` (#0121); `[]` while disconnected.
    @ObservationIgnored var activity: [OutputActivity] = []
    @ObservationIgnored var activityTask: Task<Void, Never>?
    /// The next activity snapshot follows a `.connected`, so it may adopt a paused player too.
    @ObservationIgnored var activityAfterConnect = true
    @ObservationIgnored var musicAssistantIsConnected = false
    /// Roadie itself asked Music Assistant to play on This Mac; cleared when the stream starts.
    @ObservationIgnored var ownStreamRequested = false
    private(set) var nowPlaying: NowPlaying = .idle(on: OutputDevice.thisMacID)
    private var nowPlayingTask: Task<Void, Never>?
    /// Follows the remote queue the playlist window shows (#0144).
    private var queueTask: Task<Void, Never>?
    /// Where the playlist's rows come from; Jump to File tells "can't be listed" from an empty queue by it (#0176).
    private(set) var queueRowsSource: QueueRowsSource = .local
    var playbackState: NowPlaying.State { nowPlaying.state }
    var isLoading: Bool { nowPlaying.state == .loading }
    /// Skin points per skin pixel: `baseScale`, or twice that in double size.
    var scale: CGFloat = PlayerModel.baseScale * (UserDefaults.standard.bool(forKey: PlayerModel.doubleSizeKey) ? 2 : 1) {
        didSet { visualizer.setScale(scale) }
    }
    /// Whether the skinned windows float above other apps' windows (the clutter bar's A). Persisted.
    private(set) var isAlwaysOnTop = UserDefaults.standard.bool(forKey: PlayerModel.alwaysOnTopKey)
    /// Whether the skinned windows are drawn at twice the normal size (the clutter bar's D). Persisted.
    private(set) var isDoubleSize = UserDefaults.standard.bool(forKey: PlayerModel.doubleSizeKey)
    /// Whether the main window is collapsed to its 14 px shade strip. Persisted, so the window comes back as it was left.
    private(set) var isMainWindowShaded = UserDefaults.standard.bool(forKey: PlayerModel.mainWindowShadeKey)
    /// Whether the equalizer and playlist windows are collapsed to their shade strips; persisted like the main window's.
    private(set) var isEQWindowShaded = UserDefaults.standard.bool(forKey: PlayerModel.eqWindowShadeKey)
    /// LIST › Load on a Music Assistant queue shows the playlist picker sheet (#0146).
    var isPickingPlaylist = false
    private(set) var isPlaylistWindowShaded = UserDefaults.standard.bool(forKey: PlayerModel.playlistWindowShadeKey)
    /// The main window's size in skin pixels in its current mode.
    var mainWindowSkinSize: CGSize { isMainWindowShaded ? MainWindowLayout.shadeSize : MainWindowLayout.size }
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
    var isShuffled: Bool { playsLocalQueue && player.isShuffled }
    var isRepeating: Bool { playsLocalQueue && player.repeatMode != .off }
    /// Commands go through one serial stream so a fast slider drag reaches the output in order.
    private let commandStream: AsyncStream<(TransportCommand, OutputDevice.ID)>.Continuation
    /// What the main window marquee shows: a notice, else the slider override, else the now-playing text.
    /// The queue number comes from the local player's queue, which only backs the This Mac output.
    var marqueeText: String {
        if let notice { return notice.text }
        if let marqueeOverride { return marqueeOverride }
        let number = playsLocalQueue ? player.queue.currentIndex.map { $0 + 1 } : nil
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
    static let mainWindowShadeKey = "mainWindowShade"
    static let eqWindowShadeKey = "equalizerWindowShade"
    static let playlistWindowShadeKey = "playlistWindowShade"
    static let equalizerKey = "equalizer"
    static let lastSkinKey = "lastSkinPath"
    private static let timeModeKey = "timeMode"
    static let alwaysOnTopKey = "alwaysOnTop"
    static let doubleSizeKey = "doubleSize"
    /// The normal size: one skin pixel is two points.
    static let baseScale: CGFloat = 2

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        UserDefaults.standard.set(isAlwaysOnTop, forKey: Self.alwaysOnTopKey)
    }

    func toggleDoubleSize() {
        isDoubleSize.toggle()
        UserDefaults.standard.set(isDoubleSize, forKey: Self.doubleSizeKey)
        scale = Self.baseScale * (isDoubleSize ? 2 : 1)
    }

    /// The current track for the File Info panel. Other outputs only report the `NowPlaying` snapshot.
    var currentTrackInfo: TrackInfo? {
        if playsLocalQueue {
            return player.queue.current.map { TrackInfo(track: $0, format: player.currentFormat) }
        }
        guard let title = nowPlaying.title else { return nil }
        return TrackInfo(
            title: title, artist: nowPlaying.artist ?? "", album: nowPlaying.album, duration: nowPlaying.duration)
    }

    func showFileInfo() {
        guard let info = currentTrackInfo else {
            NSSound.beep()
            return
        }
        FileInfoPanel.shared.show(info)
    }

    /// The playlist's MISC › File Info: the given track (local queue), same panel as the clutter bar's I button.
    func showFileInfo(for track: Track) {
        let format = player.queue.current?.id == track.id ? player.currentFormat : nil
        FileInfoPanel.shared.show(TrackInfo(track: track, format: format))
    }

    /// Winamp's Generate HTML Playlist: writes the page to the temporary directory and opens it in the browser.
    /// Never touches the queue.
    func generateHTMLPlaylist() {
        let url = FileManager.default.temporaryDirectory.appending(path: "Roadie Playlist.html")
        do {
            try PlaylistHTML.document(entries: playlist.htmlEntries)
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            Self.log.error("HTML playlist write failed: \(error.localizedDescription, privacy: .public)")
            post(StatusNotice(text: "Couldn't write the HTML playlist", detail: error.localizedDescription))
        }
    }

    /// Elapsed or remaining time in the main window; Winamp keeps it in winamp.ini.
    var timeMode: TimeMode = UserDefaults.standard.string(forKey: PlayerModel.timeModeKey)
        .flatMap(TimeMode.init(rawValue:)) ?? .elapsed

    func toggleTimeMode() {
        timeMode = timeMode == .elapsed ? .remaining : .elapsed
        UserDefaults.standard.set(timeMode.rawValue, forKey: Self.timeModeKey)
    }

    func setTimeMode(_ mode: TimeMode) {
        guard mode != timeMode else { return }
        timeMode = mode
        UserDefaults.standard.set(timeMode.rawValue, forKey: Self.timeModeKey)
    }

    /// What the main window's time, kbps/kHz and mono/stereo area shows. On This Mac the position, track
    /// metadata and opened file format come from the local player (read every 100 ms tick); other
    /// outputs only report the `NowPlaying` snapshot, which has no bitrate or format.
    var mainWindowStatus: MainWindowStatus { mainWindowStatus(at: Date()) }

    /// `mainWindowStatus` with a non-local output's elapsed time worked out for `now` (a `RemoteClock` tick).
    func mainWindowStatus(at now: Date) -> MainWindowStatus {
        let transport: Transport = switch nowPlaying.state {
        case .stopped: .stopped
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        }
        let isLocal = playsLocalQueue
        // This Mac fed by Music Assistant: time from the snapshot, format from the stream the player plays (#0109).
        let isThisMac = selectedOutput == OutputDevice.thisMacID
        let track = isLocal ? player.queue.current : nil
        return MainWindowStatus(
            transport: transport, timeMode: timeMode,
            elapsed: isLocal ? player.currentTime : nowPlaying.elapsed(at: now),
            duration: nowPlaying.duration ?? track?.duration ?? 0,
            bitrateKbps: track?.bitrate,
            sampleRate: (isThisMac ? player.currentFormat?.sampleRate : nil) ?? track?.sampleRate,
            channels: (isThisMac ? player.currentFormat?.channels : nil) ?? track?.channels)
    }

    init() {
        LegacyDataCleanup.run()
        let stack = LocalPlaybackStack.standard()
        player = stack.player
        playlist = PlaylistModel(player: stack.player)
        visualizer = VisualizerModel(player: stack.player, colors: VisRenderer.defaultColors)
        folderBackend = FolderBackend(settings: FolderBackend.settingsProvider(), output: stack.output)
        folderSettings = FolderSettingsModel(backend: folderBackend)
        // Music Assistant is the default source. Defaults only here: no Keychain, network or prompt at launch.
        let maStore = MusicAssistantServerStore()
        // #0075: the selection decides which server; the active box starts empty and follows it. Neither adapter
        // does I/O when constructed, and nothing probes until the Library or #0067 asks for the server.
        let maActive = MusicAssistantActiveServer()
        let wifi = SystemWiFiNetwork()
        let selection = MusicAssistantSelectionController(
            store: maStore, active: maActive, selector: MusicAssistantServerSelector(fetch: MusicAssistantServerSelector.urlSessionFetcher),
            wifi: wifi, network: SystemNetworkEvents(), clock: ContinuousClock())
        let ma = MusicAssistantBackend(
            server: { await selection.currentOrResolve() },
            token: { try KeychainMusicAssistantTokenStore(account: $0.keychainAccount).load() },
            hasVerifiedServer: { MusicAssistantServerStore.hasVerifiedServer(defaults: .standard) })
        musicAssistant = ma
        musicAssistantActive = maActive
        musicAssistantSelection = selection
        musicAssistantSettings = MusicAssistantSettingsModel(
            store: maStore, tokenStore: { KeychainMusicAssistantTokenStore(account: $0) }, test: MusicAssistantConnectionTest(),
            active: maActive, wifi: wifi)
        musicAssistantDiscovery = MusicAssistantDiscoveryModel(
            store: maStore, browser: SystemServiceBrowser(), fetch: MusicAssistantServerSelector.urlSessionFetcher,
            clock: ContinuousClock())
        sources = LibrarySourceController(
            sources: [
                LibrarySource(
                    backend: ma, isConfigured: { MusicAssistantServerStore.hasVerifiedServer(defaults: .standard) },
                    probe: SourceProbes.checking {
                        guard await selection.resolveNow() != nil else {
                            throw MusicBackendError.unreachable(MusicAssistantServerRanking.noneReachableText)
                        }
                        try await ma.probe()
                    }),
                LibrarySource(
                    backend: folderBackend, isConfigured: { FolderBackend.storedFolder() != nil },
                    probe: SourceProbes.checking { try FolderBackend.checkReachable() }),
            ],
            defaultSourceID: ma.sourceID)
        fallback = LibraryFallbackController(sources: sources)
        // This Mac is the folder backend's output (`LocalPlaybackStack`; no connection needed).
        let feedState = ThisMacFeedState()
        self.feedState = feedState
        router = PlaybackRouter(local: folderBackend, remote: ma, feed: feedState)
        sendspinController = SendspinController(sendspin: stack.sendspin, musicAssistant: ma)
        outputPicker = OutputPickerModel(remote: ma, isConnected: { await ma.isConnected })
        let (commands, continuation) = AsyncStream.makeStream(of: (TransportCommand, OutputDevice.ID).self)
        commandStream = continuation
        // Restore the queue stopped at the saved track (nothing plays, no audio device opens), then start saving changes.
        let queueStore = QueueStore(fileURL: QueueStore.defaultURL())
        let loaded = queueStore.loadQueue()
        if let loaded { stack.output.restore(loaded.snapshot) }
        queueAutosaver = QueueAutosaver(output: stack.output, store: queueStore)
        queueAutosaver.start()
        // A queue saved with a removed source kind lost those items on load; rewrite it once so they leave the disk.
        if (loaded?.droppedItems ?? 0) > 0 { queueAutosaver.saveNow() }
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
                do { try await self.router.backend(for: output, command: command).transport(command, on: output) } catch {
                    // A speaker has no balance: the marquee already shows the balance text, so no notice per drag tick.
                    if case .setBalance = command, output != OutputDevice.thisMacID,
                        error as? MusicBackendError == .unsupported(.remoteOutputs)
                    {
                        continue
                    }
                    self.showBackendFailure(error)
                }
            }
        }
        playlist.isLocal = { [weak self] in self?.selectedOutput == OutputDevice.thisMacID }
        playlist.isPlayingLocalQueue = { [weak self] in self?.playsLocalQueue ?? false }
        playlist.onPlayLocal = { [weak self] in
            self?.applyFeed(.localPlayRequested)
            self?.stopOthers(startingOn: OutputDevice.thisMacID)
        }
        playlist.onPlayRemote = { [weak self] index in self?.playRemoteQueueRow(index) }
        playlist.onRemoteRefused = { [weak self] in
            self?.post(StatusNotice(text: "Not for Music Assistant queues"))
        }
        playlist.onEditRemote = { [weak self] edit in try await self?.editRemoteQueue(edit) }
        playlist.onRemoteNotice = { [weak self] text in self?.post(StatusNotice(text: text)) }
        // Music Assistant started playing on this Mac (from Roadie, its own UI, Home Assistant or a phone).
        stack.sendspin.onStreamStarted = { [weak self] in self?.streamStarted() }
        // The server ended the stream, or the session dropped or was stopped: This Mac plays its local queue again.
        stack.sendspin.onStreamStopped = { [weak self] in self?.applyFeed(.streamStopped) }
        // Local playback took the node: Music Assistant stops sending.
        stack.sendspin.onStreamPreempted = { [weak self] in
            guard let self else { return }
            self.applyFeed(.localPlayRequested)
            let ma = self.musicAssistant
            Task { try? await ma.transport(.stop, on: OutputDevice.thisMacID) }
        }
        sendspinController.start()
        let routing = NowPlayingRouting(player: stack.player, model: self)
        nowPlayingRouting = routing
        nowPlayingBridge.setCommandTarget(routing)
        visualizer.setLayout(shaded: isMainWindowShaded, scale: scale)
        visualizer.start()
        observeNowPlaying()
        if let path = UserDefaults.standard.string(forKey: Self.lastSkinKey) {
            loadSkin(from: URL(filePath: path))
        }
        skinLibrary.passFinished = { [weak self] in
            guard let self else { return }
            skinBrowser.indexDidChange()
            if museumBrowserCreated { museumBrowser.indexDidChange() }
        }
        skinBrowser.onTrashed = { [weak self] in
            guard let self, museumBrowserCreated else { return }
            museumBrowser.indexDidChange()
        }
        musicAssistantSettings.onServersChanged = { [weak selection] in selection?.serversEdited() }
        musicAssistantDiscovery.onConfiguredServerMoved = { [weak settings = musicAssistantSettings] id, serverID, url in
            settings?.adoptDiscoveredAddress(url, for: id, serverID: serverID)
        }
        selection.onChange = { [weak self] old, new in
            self?.sendspinController.serverChanged()
            self?.musicAssistantServerChanged(from: old, to: new)
        }
        fallback.onNotice = { [weak self] in self?.post(StatusNotice(text: $0.text, detail: $0.detail)) }
        fallback.start()
        selection.start()
        // #0121: connect at launch when a verified server exists, so Roadie follows what Music Assistant plays.
        if MusicAssistantServerStore.hasVerifiedServer(defaults: .standard) {
            Task { [weak self] in
                _ = await selection.resolveNow()
                do { try await ma.connect() } catch { return }
                await self?.refreshOutputs()
            }
        }
        watchPlaybackActivity()
        // A browse failure on Music Assistant also re-picks the server; the fallback keeps its own handling.
        let fallbackFailure = sources.onBackendFailure
        sources.onBackendFailure = { [weak selection] id, error, phase in
            fallbackFailure?(id, error, phase)
            guard id == ma.sourceID else { return }
            switch error {
            case .unreachable: selection?.activeServerDropped()
            default: break
            }
        }
        watchMusicAssistantConnection()
        // The model lives as long as the app, so these observers are never removed.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fallback.settingsChanged() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.musicAssistantSelection.serversChanged()
                self?.fallback.retryNow()
            }
        }
    }

    @ObservationIgnored private var outputMoveTask: Task<Void, Never>?

    /// The Output menu's choice (#0117): moves what plays to `target` (Music Assistant's queue transfer), else only
    /// selects it. Fallback reassignments set `selectedOutput` directly and never transfer.
    func selectOutput(_ target: OutputDevice.ID) {
        let source = selectedOutput
        guard target != source else { return }
        let state = nowPlaying.output == source ? nowPlaying.state : .stopped
        let move = OutputMove.decide(from: source, to: target, sourceState: state, thisMacFeed: thisMacFeed)
        // Moving onto This Mac: Music Assistant feeds it from now on, so the windows follow its stream (#0109/#0114).
        if case .transfer = move, target == OutputDevice.thisMacID {
            ownStreamRequested = true
            applyFeed(.musicAssistantPlayRequested)
        }
        selectedOutput = target
        switch move {
        case .select: break
        case .keepLocal: post(StatusNotice(text: OutputMove.localStaysText))
        case .transfer(let autoPlay):
            let remote = router.remote
            let previous = outputMoveTask
            outputMoveTask = Task { [weak self] in
                await previous?.value  // quick re-picks transfer in order
                do { try await remote.transfer(from: source, to: target, autoPlay: autoPlay) } catch {
                    guard let self else { return }
                    if target == OutputDevice.thisMacID {
                        self.applyFeed(
                            .musicAssistantPlayFailed(isStreaming: self.sendspinController.sendspin.isStreaming))
                    }
                    self.showBackendFailure(error)
                }
            }
        }
    }

    /// The popover's checkbox (#0118): adds `id` to the synced outputs, or drops it.
    func toggleOutput(_ id: OutputDevice.ID) {
        let (next, steps) = outputSelection.toggling(id, devices: outputPicker.devices)
        applyOutputSelection(next, steps: steps)
    }

    /// The popover's "Only" (and a group row): ungroups, then moves to `id`.
    func selectOnlyOutput(_ id: OutputDevice.ID) {
        let (next, steps) = outputSelection.selectingOnly(id)
        applyOutputSelection(next, steps: steps)
    }

    /// Shows `next` at once, then runs `steps` in order after any earlier ones. A failure puts the selection back.
    private func applyOutputSelection(_ next: OutputSelection, steps: [OutputSelection.Step]) {
        guard !steps.isEmpty else { return }
        let previous = outputSelection
        outputSelection = next
        let ma = musicAssistant
        let earlier = outputSelectionTask
        outputSelectionTask = Task { [weak self] in
            await earlier?.value
            var moved = false
            do {
                for step in steps {
                    switch step {
                    case .setMembers(let leader, let add, let remove):
                        try await ma.setGroupMembers(of: leader, adding: add, removing: remove)
                    case .move(let target):
                        guard let self else { return }
                        moved = true
                        self.selectOutput(target)
                        await self.outputMoveTask?.value
                    }
                }
            } catch {
                guard let self else { return }
                self.outputSelection = moved ? OutputSelection(leader: self.selectedOutput) : previous
                self.showBackendFailure(error)
            }
        }
    }

    /// Moves the feed of This Mac by the `ThisMacFeed.after` rule (#0114).
    func applyFeed(_ event: ThisMacFeedEvent) { setThisMacFeed(thisMacFeed.after(event)) }

    /// Switches what feeds This Mac and follows the new owner's now-playing stream.
    func setThisMacFeed(_ feed: ThisMacFeed) {
        guard feed != feedState.feed else { return }
        feedState.feed = feed
        observeNowPlaying()
    }

    /// The selection picked another server (#0075). Playback on This Mac is never touched.
    private func musicAssistantServerChanged(from old: MusicAssistantServerConfiguration?, to new: MusicAssistantServerConfiguration?) {
        let isSelected = sources.selectedID == musicAssistant.sourceID
        if new == nil {
            if isSelected {
                let ma = musicAssistant
                Task { await ma.disconnect() }
                fallback.report(MusicBackendError.unreachable(MusicAssistantServerRanking.noneReachableText), from: ma.sourceID)
            }
            return
        }
        if isSelected {
            activeMusicAssistantServerChanged()
        } else {
            fallback.retryNow()
        }
        if old != nil, let new {
            post(StatusNotice(text: "Music Assistant: " + Self.truncated(new.name, to: 31 - "Music Assistant: ".utf16.count)))
        }
    }

    static func truncated(_ text: String, to units: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf16.count + String(character).utf16.count <= units else { break }
            result.append(character)
        }
        return result
    }

    /// A Music Assistant client that failed, or kept reconnecting for more than 10 s, makes the selection re-pick.
    private func watchMusicAssistantConnection() {
        let ma = musicAssistant
        maDropTask = Task { [weak self] in
            var reconnectTimer: Task<Void, Never>?
            for await state in await ma.connectionStates() {
                guard let self else { return }
                switch state {
                case .connected:
                    self.musicAssistantIsConnected = true
                    // A snapshot that beat `.connected` already counted as the connect one (#0121 review).
                    if self.activity.isEmpty { self.activityAfterConnect = true }
                case .disconnected, .failed:
                    self.musicAssistantIsConnected = false
                default: break
                }
                switch state {
                case .failed:
                    reconnectTimer?.cancel()
                    reconnectTimer = nil
                    self.musicAssistantSelection.activeServerDropped()
                case .reconnecting:
                    guard reconnectTimer == nil else { continue }
                    let selection = self.musicAssistantSelection
                    reconnectTimer = Task {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        selection.activeServerDropped()
                    }
                default:
                    reconnectTimer?.cancel()
                    reconnectTimer = nil
                }
            }
        }
    }

    /// The server the backend uses changed: drop the connection (the next browse reconnects to the new one) and rebuild
    /// the Library if Music Assistant is what it shows. A track playing on This Mac is not touched.
    private func activeMusicAssistantServerChanged() {
        let ma = musicAssistant
        let sources = sources
        // The old server's players are gone with it.
        if outputSelection != .thisMac {
            let wasThisMac = selectedOutput == OutputDevice.thisMacID
            outputSelection = .thisMac
            selectedOutput = OutputDevice.thisMacID
            if !wasThisMac { post(StatusNotice(text: "Output switched to This Mac")) }
        }
        let picker = outputPicker
        Task {
            await ma.disconnect()
            sources.reload(ma.sourceID)
            await picker.refresh()
        }
    }

    /// Lists the outputs again (the Library connected, the Output menu opened). A selected speaker that is no longer
    /// listed falls back to the next checked one, else This Mac (#0118); a failed or unconnected listing leaves the
    /// selection alone.
    func refreshOutputs() async {
        await outputPicker.refresh()
        guard outputPicker.hint == nil else { return }
        let reconciled = outputSelection.reconciled(with: outputPicker.devices)
        guard reconciled != outputSelection else { return }
        outputSelection = reconciled
        if reconciled.leader != selectedOutput {
            selectedOutput = reconciled.leader
            let name = outputPicker.devices.first { $0.id == reconciled.leader }?.name ?? OutputDevice.thisMac.name
            post(StatusNotice(text: "Output switched to " + Self.truncated(name, to: 31 - "Output switched to ".utf16.count)))
        }
    }

    /// Follows the selected output's now-playing stream, from the backend that owns the output. Never connects: the
    /// stream for This Mac works without a server, and Music Assistant's is idle until the Library connects it.
    private func observeNowPlaying() {
        observeQueue()
        nowPlayingTask?.cancel()
        externalArtworkTask?.cancel()
        externalArtwork = nil
        let output = selectedOutput
        let backend = router.backend(for: output)
        let isRemote = !playsLocalQueue
        nowPlaying = .idle(on: output)
        if isRemote {
            nowPlayingBridge.showExternal(nil, artwork: nil)
        } else {
            nowPlayingBridge.clearExternal()
        }
        nowPlayingTask = Task { [weak self] in
            for await snapshot in await backend.nowPlaying(on: output) {
                guard !Task.isCancelled, let self else { return }
                self.nowPlaying = snapshot
                if let volume = snapshot.volume, self.sliderFocus != .volume { self.volume = volume }
                if isRemote { self.publishExternal(snapshot) }
            }
        }
    }

    /// Points the playlist window at the selected output's queue (#0144): the local queue, or the backend's
    /// remote queue followed through `queue(on:)`.
    private func observeQueue() {
        queueTask?.cancel()
        queueTask = nil
        let output = selectedOutput
        let backend = router.backend(for: output)
        let source = QueueRowsSelection.choose(output: output, feed: thisMacFeed, remoteCapabilities: backend.capabilities)
        queueRowsSource = source
        switch source {
        case .local:
            playlist.remote = nil
        case .none:
            playlist.remote = .empty(on: output)
        case .remote(let target):
            if playlist.remote?.output != target { playlist.remote = .empty(on: target) }
            queueTask = Task { [weak self] in
                for await snapshot in await backend.queue(on: target) {
                    guard !Task.isCancelled, let self else { return }
                    self.playlist.remote = snapshot
                }
            }
        }
    }

    /// Double-click or Return on a remote queue row: `player_queues/play_index` (#0144).
    private func playRemoteQueueRow(_ index: Int) {
        let output = selectedOutput
        let backend = router.backend(for: output)
        Self.log.debug("play_index \(index, privacy: .public) on remote queue")
        Task { [weak self] in
            do {
                try await backend.edit(.play(index: index), on: output)
            } catch {
                self?.showBackendFailure(error)
            }
        }
    }

    /// A remove, move or clear from the playlist editor on a remote queue (#0145).
    private func editRemoteQueue(_ edit: QueueEdit) async throws {
        let output = selectedOutput
        try await router.backend(for: output).edit(edit, on: output)
    }

    /// Control Center for a remote output: the snapshot now, its artwork once fetched (on a change of ref only).
    private func publishExternal(_ snapshot: NowPlaying) {
        let ref = snapshot.artwork
        if ref != externalArtwork?.ref {
            externalArtworkTask?.cancel()
            externalArtwork = ref.map { (ref: $0, data: nil as Data?) }
            if let ref {
                let ma = musicAssistant
                externalArtworkTask = Task { [weak self] in
                    let data = try? await ma.artwork(ref, maxPixels: 512)
                    guard !Task.isCancelled, let self, self.externalArtwork?.ref == ref else { return }
                    self.externalArtwork = (ref, data)
                    self.nowPlayingBridge.showExternal(Self.systemSnapshot(self.nowPlaying), artwork: data)
                }
            }
        }
        nowPlayingBridge.showExternal(Self.systemSnapshot(snapshot), artwork: externalArtwork?.data)
    }

    /// `NowPlaying` as the system's Now Playing sees it; nil when stopped.
    static func systemSnapshot(_ snapshot: NowPlaying, at now: Date = Date()) -> NowPlayingSnapshot? {
        let state: PlaybackState
        switch snapshot.state {
        case .stopped: return nil
        case .loading, .paused: state = .paused
        case .playing: state = .playing
        }
        return NowPlayingSnapshot(
            title: snapshot.title ?? "Unknown title", artist: snapshot.artist ?? ArtistName.unknown,
            album: snapshot.album, duration: snapshot.duration ?? 0, elapsed: snapshot.elapsed(at: now), state: state)
    }

    /// Writes the queue now; called on quit so the last second of changes is not lost.
    func flushQueue() { queueAutosaver.flush() }

    /// Museum › Move to Trash for a downloaded skin (#0131): the same path as the Library's, keyed by the file.
    func trashDownloadedMuseumSkin(at url: URL) {
        guard let root = skinLibrary.folderURL, let path = SkinBrowserFormat.relativePath(of: url, in: root) else {
            skinBrowser.trashError = "“\(url.lastPathComponent)” is not in the skins folder."
            return
        }
        Task { await skinBrowser.moveToTrash(path: path) }
    }

    func loadSkin(from url: URL) {
        // Two quick applies (holding the Next Skin shortcut) race; the newest request wins and the older parse is dropped.
        skinLoadGeneration += 1
        let generation = skinLoadGeneration
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let skin = try SkinParser.parse(url: url)
                    return (skin, MainWindowBase(skin: skin))
                }
            }.value
            guard generation == skinLoadGeneration else { return }
            switch result {
            case .success(let (skin, base)):
                self.skin = skin
                mainWindowBase = base
                visualizer.setColors(skin.visColors)
                skinName = url.deletingPathExtension().lastPathComponent
                errorMessage = nil
                UserDefaults.standard.set(url.path, forKey: Self.lastSkinKey)
                for warning in skin.warnings { print("[\(url.lastPathComponent)] \(warning)") }
                skinBrowser.skinDidLoad(from: url)
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

    func send(_ command: TransportCommand) {
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
    var positionFraction: Double? { positionFraction(at: Date()) }

    /// Start of the 1 s clock that re-renders the time and position views while a non-local output plays;
    /// nil otherwise (This Mac re-renders from the player's own ticks, and idle/paused need no clock).
    var remoteClockAnchor: Date? { nowPlaying.remoteClockAnchor(followsLocalPlayer: playsLocalQueue) }

    func positionFraction(at now: Date) -> Double? {
        let status = mainWindowStatus(at: now)
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

    /// ±5 s from the current position (a Winamp arrow key). No-op unless a track with a known length is playing or paused.
    func seek(forward: Bool) {
        guard positionFraction != nil else { return }
        let status = mainWindowStatus
        guard let target = WinampHotkeys.seekTarget(elapsed: status.elapsed, duration: status.duration, forward: forward)
        else { return }
        send(.seek(target))
    }

    /// ±1 % (a Winamp arrow key). Leaves `sliderFocus` and the marquee alone, unlike a slider drag.
    func nudgeVolume(up: Bool) {
        volume = WinampHotkeys.nudgedVolume(volume, up: up)
        send(.setVolume(volume))
    }

    /// One Winamp hotkey, from the Playback menu or a bare key in a skinned window.
    func perform(_ hotkey: WinampHotkey) {
        switch hotkey {
        case .previous: previous()
        case .play: play()
        case .pause: pause()
        case .stop: stop()
        case .next: next()
        case .seekBack: seek(forward: false)
        case .seekForward: seek(forward: true)
        case .volumeUp: nudgeVolume(up: true)
        case .volumeDown: nudgeVolume(up: false)
        case .toggleShuffle: toggleShuffle()
        case .toggleRepeat: toggleRepeat()
        case .openFile: openFiles(replace: true)
        case .jumpToFile: showJumpToFile()
        }
    }

    /// Opens or brings forward the Jump to File panel (J, ⌘J, #0176).
    func showJumpToFile() { JumpToFilePanel.shared.show(model: self) }

    /// Collapses the main window to its shade strip or restores it (the shade button, a title-bar double-click and
    /// Window > Windowshade all come here). `SkinWindowController` follows the flag.
    func toggleMainWindowShade() {
        isMainWindowShaded.toggle()
        UserDefaults.standard.set(isMainWindowShaded, forKey: Self.mainWindowShadeKey)
        visualizer.setLayout(shaded: isMainWindowShaded, scale: scale)
    }

    func toggleEQWindowShade() {
        isEQWindowShaded.toggle()
        UserDefaults.standard.set(isEQWindowShaded, forKey: Self.eqWindowShadeKey)
    }

    func togglePlaylistWindowShade() {
        isPlaylistWindowShaded.toggle()
        UserDefaults.standard.set(isPlaylistWindowShaded, forKey: Self.playlistWindowShadeKey)
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

    private static let log = Logger(subsystem: "co.sstools.roadie", category: "Playback")

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
        case .next: mode = "next"
        case .insert: mode = "insert"
        }
        Self.log.info("play from library: \(request.items.count, privacy: .public) item(s), \(mode, privacy: .public)")
        let backend = backend
        let sourceID = backend.sourceID
        let output = selectedOutput
        // Local files play only on This Mac. Not a source failure, so the fallback is not told.
        if let text = LocalPlaybackGate.refusal(source: backend.capabilities, output: output)
            ?? (outputSelection.members.isEmpty || backend.capabilities.contains(.remoteOutputs)
                ? nil : LocalPlaybackGate.switchToThisMac)
        {
            post(StatusNotice(text: text))
            return
        }
        if output == OutputDevice.thisMacID {
            applyFeed(sourceID == musicAssistant.sourceID ? .musicAssistantPlayRequested : .localPlayRequested)
        }
        let maOnThisMac = output == OutputDevice.thisMacID && sourceID == musicAssistant.sourceID
        if maOnThisMac { ownStreamRequested = true }
        let stopping = stopOthers(startingOn: output)
        Task {
            await stopping?.value
            do { try await backend.play(request.items, on: output, mode: request.mode) } catch {
                // A failed Music Assistant play hands This Mac back unless an earlier stream still runs (#0114).
                if maOnThisMac { applyFeed(.musicAssistantPlayFailed(isStreaming: sendspinController.sendspin.isStreaming)) }
                // `.backend` (Music Assistant on This Mac, #0066) is not a source failure; `report` ignores it.
                fallback.report(error, from: sourceID)
                showBackendFailure(error)
            }
        }
    }

    /// Winamp's eject button opens the file dialog.
    func eject() { openFiles(replace: true) }

    /// Shows the open panel for audio files, folders, playlists and skins. Open replaces the queue and plays;
    /// Add appends. A chosen `.wsz` loads as the skin. The app is not sandboxed, so the returned
    /// URLs are directly readable. Unlike Add Dir and Load List, the panel still shows while a speaker is
    /// selected, because it also picks skins; `importLocalFiles` refuses only the audio part (#0084).
    func openFiles(replace: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = LocalTrackLoader.audioTypes + LocalTrackLoader.playlistTypes + [.wsz]
        panel.message = "Choose audio files, folders, playlists or a skin"
        panel.prompt = replace ? "Open" : "Add"
        Task {
            guard await panel.begin() == .OK else { return }
            open(panel.urls, replace: replace)
        }
    }

    /// The playlist's ADD › Add Dir: folders only, appended.
    func openFolder() {
        if let text = LocalPlaybackGate.refusal(forLocalFilesOn: outputSelection) {
            post(StatusNotice(text: text))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to add"
        panel.prompt = "Add"
        Task {
            guard await panel.begin() == .OK else { return }
            importLocalFiles(panel.urls, replace: false)
        }
    }

    /// #0169: what earlier launches left in the defaults. Read before the default skins folder is applied.
    func firstRunState(defaults: UserDefaults = .standard) -> FirstRunState {
        Self.firstRunState(defaults: defaults)
    }

    /// Static so it needs no model (#0193).
    static func firstRunState(defaults: UserDefaults) -> FirstRunState {
        FirstRunState(
            completedVersion: defaults.integer(forKey: FirstRunPolicy.defaultsKey),
            hasSkinsFolder: defaults.string(forKey: SkinLibraryModel.folderKey) != nil,
            hasLastSkin: defaults.string(forKey: Self.lastSkinKey) != nil,
            hasMusicFolder: FolderBackend.storedFolder(in: defaults) != nil,
            hasVerifiedServer: MusicAssistantServerStore.hasVerifiedServer(defaults: defaults))
    }

    func markFirstRunCompleted(defaults: UserDefaults = .standard) {
        defaults.set(FirstRunPolicy.currentVersion, forKey: FirstRunPolicy.defaultsKey)
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
    /// Returns true even when the audio was refused on a speaker (#0084): the drop was received and the notice
    /// says why nothing played.
    func open(_ urls: [URL], replace: Bool, at row: Int? = nil) -> Bool {
        let isSkin = { (url: URL) in url.pathExtension.lowercased() == "wsz" }
        let skin = urls.first(where: isSkin)
        let others = urls.filter { !isSkin($0) }
        if let skin { loadSkin(from: skin) }
        importLocalFiles(others, replace: replace, at: row)
        return skin != nil || !others.isEmpty
    }

    /// Loads files and folders off the main actor, then queues them. Replacing clears the queue
    /// and starts the first new track; appending only starts playback on an idle, empty player. Refused with a
    /// notice while a speaker is selected, checked again after the load in case the output changed (#0084). Appending
    /// with a `row` inserts before that row instead (a drop on the track list, #0183).
    func importLocalFiles(_ urls: [URL], replace: Bool, at row: Int? = nil) {
        guard !urls.isEmpty else { return }
        if let text = LocalPlaybackGate.refusal(forLocalFilesOn: outputSelection) {
            post(StatusNotice(text: text))
            return
        }
        Task {
            let result = await LocalTrackLoader.load(urls)
            if let text = LocalPlaybackGate.refusal(forLocalFilesOn: outputSelection) {
                post(StatusNotice(text: text))
                return
            }
            if let skipped = StatusNotice.skipped(result) { post(skipped) } else { clearNotice() }
            guard !result.tracks.isEmpty else { return }
            // Local files take This Mac back from Music Assistant; AudioCore then preempts the stream.
            applyFeed(.localPlayRequested)
            stopOthers(startingOn: OutputDevice.thisMacID)
            let wasIdle = player.state == .stopped && player.queue.tracks.isEmpty
            if !replace, let row {
                // The queue may have changed during the load.
                let at = min(row, player.queue.tracks.count)
                player.insert(result.tracks, at: at)
                if wasIdle { player.play(at: at) }
                return
            }
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
