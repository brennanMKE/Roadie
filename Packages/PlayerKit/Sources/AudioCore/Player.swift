import AVFoundation
import CoreAudio
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "AudioOutput")

@MainActor
@Observable
public final class Player: NowPlayingCommandTarget {
    public private(set) var queue = PlayQueue() {
        didSet { emitTrackChangeIfNeeded() }
    }
    public internal(set) var state: PlaybackState = .stopped {
        didSet { emit(.stateChanged(state)) }
    }
    public internal(set) var currentTime: TimeInterval = 0
    /// File format of the loaded track; nil while loading or stopped.
    public internal(set) var currentFormat: PlaybackFormat?
    /// The last failure's message: set by every failure, cleared when a track opens. Listeners that need
    /// each failure observe `PlayerEvent.failed`.
    public internal(set) var errorMessage: String?
    /// Failures in a row since a track last opened or the player last stopped; bounds the skip run to one pass.
    @ObservationIgnored var consecutiveFailures = 0

    /// True while a progressive (still downloading) track has run out of decoded audio and is waiting for
    /// bytes: the node is paused and the position holds. Always false for a complete file.
    public internal(set) var isBuffering = false
    /// How far into a progressive track the downloaded bytes reach (seconds); nil for a complete file.
    public internal(set) var bufferedTime: TimeInterval?

    /// 0...1. Clamped on assignment; backed by an ignored stored value so the
    /// setter never re-enters itself (a `didSet` that reassigns recurses under `@Observable`).
    public var volume: Float {
        get {
            access(keyPath: \.volume)
            return storedVolume
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            withMutation(keyPath: \.volume) {
                storedVolume = clamped
            }
            _graph?.volume = clamped
        }
    }
    /// -1...1. Clamped on assignment; see `volume`.
    public var balance: Float {
        get {
            access(keyPath: \.balance)
            return storedBalance
        }
        set {
            let clamped = min(max(newValue, -1), 1)
            withMutation(keyPath: \.balance) {
                storedBalance = clamped
            }
            _graph?.balance = clamped
        }
    }
    /// Equalizer settings (10 bands, preamp, on/off). Computed over an ignored stored value for the same
    /// reason as `volume`; changes reach the engine immediately, also mid-playback.
    public var eq: EQState {
        get {
            access(keyPath: \.eq)
            return storedEQ
        }
        set {
            guard newValue != storedEQ else { return }
            withMutation(keyPath: \.eq) {
                storedEQ = newValue
            }
            _graph?.eq.apply(newValue)
        }
    }
    @ObservationIgnored private var storedEQ = EQState.flat
    @ObservationIgnored private var storedVolume: Float = 1
    @ObservationIgnored private var storedBalance: Float = 0
    public var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            reconcileSchedule()
        }
    }
    public var isShuffled: Bool {
        get { queue.isShuffled }
        set {
            queue.setShuffle(newValue)
            reconcileSchedule()
        }
    }

    /// Observers are notified (on the main actor, in registration order) when the current track,
    /// the play/pause/stop state or the position (seek) changes; never per playback tick.
    @ObservationIgnored private var eventObservers: [(token: PlayerEventToken, handler: @MainActor (PlayerEvent) -> Void)] = []

    /// Registers an event observer; keep the token and pass it to `removeEventObserver(_:)`.
    /// Any number of observers can coexist (Now Playing bridge, UI, prefetch).
    @discardableResult
    public func addEventObserver(_ handler: @escaping @MainActor (PlayerEvent) -> Void) -> PlayerEventToken {
        let token = PlayerEventToken(id: UUID())
        eventObservers.append((token, handler))
        return token
    }

    public func removeEventObserver(_ token: PlayerEventToken) {
        eventObservers.removeAll { $0.token == token }
    }

    func emit(_ event: PlayerEvent) {
        for observer in eventObservers { observer.handler(event) }
    }
    @ObservationIgnored private var lastEmittedTrackID: UUID?

    @ObservationIgnored let resolver: any TrackResolver
    @ObservationIgnored var _graph: AudioGraph?
    /// Spectrum / oscilloscope source for the visualizer. Pull `latestFrame()` from the main
    /// thread at 30-60 Hz; it is installed on the mixer whenever the engine starts.
    @ObservationIgnored public let analyzer = AnalyzerTap()
    /// Test-only: when on, `schedule` and `segmentFinished` append to the capped diagnostic arrays below.
    @ObservationIgnored var recordsDiagnostics = false
    @ObservationIgnored private(set) var scheduleDiagnostics: [ScheduleDiagnostic] = []
    @ObservationIgnored private(set) var completionDiagnostics: [GaplessScheduler.CompletionOutcome] = []
    @ObservationIgnored var file: AVAudioFile?
    /// The pre-scheduled file behind `file`, if any (its track is `scheduler.scheduledNextTrackID`).
    @ObservationIgnored private var nextFile: AVAudioFile?
    /// Decides which completion handlers are still valid and tracks the node's timeline.
    @ObservationIgnored var scheduler = GaplessScheduler()
    /// The current track when it plays from a download still in flight (#0039); `file` is nil then.
    @ObservationIgnored var progressive: ProgressiveSession?
    /// Test hooks: how the progressive reader waits and fetches, and the size of the buffers it schedules.
    @ObservationIgnored var progressivePolicy = ProgressiveReadPolicy()
    @ObservationIgnored var progressiveBufferFrames: AVAudioFrameCount?
    /// The server-timed PCM stream holding the node (#0106), or nil in file playback.
    var stream: StreamSession?
    /// Maps render times to local µs for the stream; tests in offline rendering swap in a sample clock.
    @ObservationIgnored var streamRenderClock: any StreamRenderClock = HostStreamRenderClock()
    /// Output latency the stream adds to render times, read when the stream begins and after output changes.
    @ObservationIgnored var streamLatencySeconds: Double = 0
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored var loadTask: Task<Void, Never>?
    /// What the in-flight (or last) load should do when the file opens: play, or park paused.
    /// Play, pause and toggle flip it while `state == .loading`.
    @ObservationIgnored private(set) var autoplayAfterLoad = true
    @ObservationIgnored var timeTask: Task<Void, Never>?
    @ObservationIgnored private var configTask: Task<Void, Never>?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored let outputDevices: any OutputDeviceProvider
    @ObservationIgnored private var outputReconfigurePending = false

    /// Construction does not touch the audio engine.
    public init(
        resolver: any TrackResolver = FileTrackResolver(),
        outputDevices: any OutputDeviceProvider = SystemOutputDeviceProvider()
    ) {
        self.resolver = resolver
        self.outputDevices = outputDevices
    }

    deinit {
        configTask?.cancel()
        outputTask?.cancel()
    }

    private func emitTrackChangeIfNeeded() {
        let current = queue.current
        guard current?.id != lastEmittedTrackID else { return }
        lastEmittedTrackID = current?.id
        emit(.trackChanged(current))
    }

    // MARK: Queue

    public func enqueue(_ tracks: [Track]) {
        queue.append(tracks)
        reconcileSchedule()
    }

    public func removeTrack(at index: Int) {
        let removingCurrent = queue.currentIndex == index
        if removingCurrent { currentTime = 0 }   // before the queue change publishes the new track
        queue.remove(at: index)
        if removingCurrent && state != .stopped && stream == nil {
            // Keep the transport intent: a paused player parks on the new current track at 0:00,
            // and a load in flight keeps whatever play/pause intent it has accumulated.
            let autoplay = state == .loading ? autoplayAfterLoad : state == .playing
            if queue.current != nil { startCurrentTrack(autoplay: autoplay) } else { stop() }
        } else {
            reconcileSchedule()
        }
    }

    /// Removes several tracks in one queue change and applies `removeTrack(at:)`'s transport rule once: when the current
    /// track goes, the transport restarts on the new current track with the same play/pause intent, or stops when the
    /// queue emptied. (Looping `removeTrack(at:)` would start and kill a load for every index.)
    public func removeTracks(at indices: IndexSet) {
        let valid = IndexSet(indices.filter { queue.tracks.indices.contains($0) })
        guard !valid.isEmpty else { return }
        let removingCurrent = queue.currentIndex.map { valid.contains($0) } ?? false
        if removingCurrent { currentTime = 0 }   // before the queue change publishes the new track
        queue.remove(at: valid)
        if removingCurrent && state != .stopped && stream == nil {
            let autoplay = state == .loading ? autoplayAfterLoad : state == .playing
            if queue.current != nil { startCurrentTrack(autoplay: autoplay) } else { stop() }
        } else {
            reconcileSchedule()
        }
    }

    /// Moves the tracks at `selected` by `offset` rows (see `PlayQueue.move`). The pre-scheduled next file may now be
    /// the wrong one, so the schedule is reconciled.
    public func moveTracks(_ selected: Set<Int>, by offset: Int) {
        guard queue.move(selected, by: offset) else { return }
        reconcileSchedule()
    }

    /// Sorts the list by `key` (see `PlayQueue.sort`). Playback continues; the schedule is reconciled.
    public func sortQueue(by key: (Track) -> String) {
        guard queue.sort(by: key) else { return }
        reconcileSchedule()
    }

    public func reverseQueue() {
        guard queue.reverse() else { return }
        reconcileSchedule()
    }

    public func randomizeQueue() {
        guard queue.randomize() else { return }
        reconcileSchedule()
    }

    /// Launch-time restore: only while stopped with an empty queue, and only with tracks. Appends, sets repeat,
    /// selects `currentIndex` when in range, then turns shuffle on (so the current track heads the pass).
    /// Never opens the engine or starts a load; emits `.trackChanged` like any queue change.
    @discardableResult
    public func restoreQueue(_ tracks: [Track], currentIndex: Int?, repeatMode: RepeatMode, isShuffled: Bool) -> Bool {
        guard state == .stopped, queue.tracks.isEmpty, !tracks.isEmpty else { return false }
        queue.append(tracks)
        queue.repeatMode = repeatMode
        if let currentIndex, tracks.indices.contains(currentIndex) { queue.select(currentIndex) }
        if isShuffled { queue.setShuffle(true) }
        return true
    }

    public func clearQueue() {
        if stream == nil { stop() }   // a server stream keeps playing; only the local list empties
        queue.removeAll()
    }

    // MARK: Transport

    public func play() {
        preemptStreamIfNeeded()
        switch state {
        case .playing:
            return
        case .loading:
            // The load is already in flight; just make sure it plays when it lands.
            autoplayAfterLoad = true
        case .paused:
            do {
                let graph = try startedGraph()
                if !isBuffering { graph.playerNode.play() }   // a stalled node waits for the resume
                state = .playing
                startTimeUpdates()
            } catch {
                fail(error)
            }
        case .stopped:
            if queue.current == nil {
                guard !queue.tracks.isEmpty else { return }
                queue.select(0)
            }
            startCurrentTrack()
        }
    }

    public func play(at index: Int) {
        guard queue.tracks.indices.contains(index) else { return }
        currentTime = 0   // before the queue change publishes the new track
        queue.select(index)
        startCurrentTrack()
    }

    public func pause() {
        // A server-timed stream cannot be paused locally.
        if preemptStreamIfNeeded() { return }
        switch state {
        case .playing:
            updateCurrentTime()
            _graph?.playerNode.pause()
            timeTask?.cancel()
            state = .paused
        case .loading:
            autoplayAfterLoad = false   // the track parks paused at 0:00 when it lands
        case .paused, .stopped:
            return
        }
    }

    public func togglePlayPause() { togglePause() }

    public func togglePause() {
        switch state {
        case .playing: pause()
        case .paused: play()
        case .stopped: play()
        case .loading: autoplayAfterLoad.toggle()
        }
    }

    public func stop() {
        if stream != nil { endStream() }
        consecutiveFailures = 0
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()
        _graph?.playerNode.stop()
        file = nil
        closeProgressive()
        currentFormat = nil
        currentTime = 0
        state = .stopped
    }

    public func next() {
        preemptStreamIfNeeded()
        currentTime = 0   // before the queue change publishes the new track
        if queue.next() != nil {
            startCurrentTrack()
        } else {
            stop()
        }
    }

    public func previous() {
        preemptStreamIfNeeded()
        currentTime = 0   // before the queue change publishes the new track
        if queue.previous() != nil {
            startCurrentTrack()
        } else if queue.current != nil {
            startCurrentTrack()   // restart the current track
        }
    }

    public func seek(to seconds: TimeInterval) {
        preemptStreamIfNeeded()
        if let progressive {
            seekProgressive(progressive, to: seconds)
            return
        }
        guard let file, let graph = _graph else { return }
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        let target = min(max(seconds, 0), duration)
        let frame = AVAudioFramePosition(target * rate)
        guard frame < file.length else {
            trackEnded()
            return
        }
        let wasPlaying = state == .playing
        discardSchedule()
        graph.playerNode.stop()
        schedule(file, from: frame)
        currentTime = target
        if wasPlaying {
            graph.playerNode.play()
        }
        scheduleNextIfNeeded()
        emit(.seeked(target))
    }

    // MARK: Starting tracks

    /// `autoplay: false` loads the track and parks it paused at 0:00 instead of starting it.
    func startCurrentTrack(autoplay: Bool = true) {
        preemptStreamIfNeeded()
        guard let track = queue.current else {
            stop()
            return
        }
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()   // bumps the generation: any older load is now stale
        _graph?.playerNode.stop()
        file = nil   // seek / reschedule / device change must not act on the previous track's file
        closeProgressive()
        currentFormat = nil
        currentTime = 0
        autoplayAfterLoad = autoplay
        state = .loading   // synchronous: observers and a repeated Play see the load immediately
        let generation = scheduler.generation
        let resolver = self.resolver
        loadTask = Task {
            do {
                let resolved = try await resolver.resolve(track)
                guard !Task.isCancelled, scheduler.generation == generation else {
                    if case .progressive(let source) = resolved { source.close() }
                    return
                }
                switch resolved {
                case .file(let url):
                    try begin(try AVAudioFile(forReading: url))
                case .progressive(let source):
                    try await openProgressive(source, track: track, generation: generation)
                }
            } catch {
                guard !Task.isCancelled, scheduler.generation == generation else { return }
                trackFailed(error)
            }
        }
    }

    private static func format(of file: AVAudioFile) -> PlaybackFormat {
        PlaybackFormat(sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount))
    }

    func begin(_ file: AVAudioFile) throws {
        let graph = ensureGraph()
        discardSchedule()
        graph.playerNode.stop()
        try graph.start()
        errorMessage = nil
        consecutiveFailures = 0
        self.file = file
        currentFormat = Self.format(of: file)
        schedule(file, from: 0)
        currentTime = 0
        if autoplayAfterLoad {
            graph.playerNode.play()
            state = .playing
            startTimeUpdates()
        } else {
            // Parked: the segment stays scheduled on the stopped node; `play()` resumes it from 0.
            state = .paused
        }
        scheduleNextIfNeeded()
    }

    /// Every schedule call goes through here so the scheduler's bookkeeping matches the node.
    /// `at: nil` queues the segment right behind whatever is already scheduled.
    private func schedule(
        _ file: AVAudioFile, trackID: UUID? = nil, from frame: AVAudioFramePosition = 0
    ) {
        guard let graph = _graph, let id = trackID ?? queue.current?.id else { return }
        let remaining = file.length - frame
        guard remaining > 0, let nodeRate = graph.processingSampleRate else { return }
        let fileRate = file.processingFormat.sampleRate
        let item = scheduler.append(
            trackID: id,
            frameLength: GaplessScheduler.nodeFrames(
                fileFrames: remaining, fileSampleRate: fileRate, nodeSampleRate: nodeRate),
            seekOffset: Double(frame) / fileRate)
        let token = item.token
        if recordsDiagnostics {
            record(ScheduleDiagnostic(
                trackID: id, startFrame: item.startFrame, nodeSampleTimeAtSchedule: nodeSampleTime(),
                nodeSampleRate: nodeRate, seekOffset: item.seekOffset))
        }
        graph.playerNode.scheduleSegment(
            file, startingFrame: frame, frameCount: AVAudioFrameCount(clamping: remaining), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token) }
        }
    }

    /// Invalidate before every `playerNode.stop()`: stop fires the handler of each discarded item.
    func discardSchedule() {
        preloadTask?.cancel()
        progressive?.feeder?.cancel()
        progressive?.feeder = nil
        scheduler.invalidate()
        nextFile = nil
    }

    /// Queue the track that follows the current one behind it so the node never goes silent.
    func scheduleNextIfNeeded() {
        preloadTask?.cancel()
        guard state == .playing || state == .paused, scheduler.items.count == 1,
              progressive?.hasScheduledLastBuffer ?? true,
              let index = queue.indexAfterCurrentEnds() else { return }
        let track = queue.tracks[index]
        let generation = scheduler.generation
        let resolver = self.resolver
        preloadTask = Task {
            guard let url = try? await resolver.localURL(for: track),
                  !Task.isCancelled, scheduler.generation == generation, scheduler.items.count == 1,
                  let current = queue.indexAfterCurrentEnds(), queue.tracks[current].id == track.id,
                  _graph != nil,
                  let next = try? AVAudioFile(forReading: url) else { return }
            nextFile = next
            schedule(next, trackID: track.id)
        }
    }

    /// Queue edits can make the pre-scheduled file the wrong one.
    private func reconcileSchedule() {
        guard state != .stopped, file != nil || progressive != nil, let graph = _graph else { return }
        let queueNext = queue.indexAfterCurrentEnds().map { queue.tracks[$0].id }
        switch SchedulingDecision.reconcile(queueNext: queueNext, scheduledNext: scheduler.scheduledNextTrackID) {
        case .keep:
            break
        case .scheduleNext:
            scheduleNextIfNeeded()
        case .restartCurrent:
            if state == .playing { updateCurrentTime() }
            if let progressive {
                let frame = min(Int64(currentTime * progressive.fileRate), max(progressive.lengthFrames - 1, 0))
                restartProgressive(progressive, at: frame)
                return
            }
            guard let file else { return }
            let rate = file.processingFormat.sampleRate
            let frame = min(AVAudioFramePosition(currentTime * rate), max(file.length - 1, 0))
            discardSchedule()
            graph.playerNode.stop()
            schedule(file, from: frame)
            if state == .playing { graph.playerNode.play() }
            scheduleNextIfNeeded()
        }
    }

    func segmentFinished(_ token: ScheduleToken) {
        let outcome = scheduler.complete(token)
        if recordsDiagnostics { record(outcome) }
        switch outcome {
        case .stale:
            break
        case .advanced(let id):
            // The node has already moved on to the pre-scheduled file; follow it.
            // Reset the position before the queue moves: the queue change publishes the new track
            // and observers read `currentTime` at that moment.
            let next = nextFile
            currentTime = 0
            guard queue.advanceAfterTrackEnd() != nil, queue.current?.id == id, let next else {
                startCurrentTrack()
                return
            }
            file = next
            closeProgressive()
            currentFormat = Self.format(of: next)
            nextFile = nil
            scheduleNextIfNeeded()
        case .reachedEnd:
            trackEnded()
        }
    }

    /// The current track finished with nothing pre-scheduled behind it.
    func trackEnded() {
        currentTime = 0
        if queue.advanceAfterTrackEnd() != nil {
            startCurrentTrack()
        } else {
            stop()
        }
    }

    // MARK: Time

    func updateCurrentTime() {
        if stream != nil {
            updateStreamTime()
            return
        }
        guard file != nil || progressive != nil, let node = _graph?.playerNode,
              let renderTime = node.lastRenderTime,
              // Invalid before the first render (offline mode, or just after a restart); passing it
              // to playerTime(forNodeTime:) raises an Objective-C exception.
              renderTime.isSampleTimeValid || renderTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime),
              let seconds = scheduler.position(
                atNodeSampleTime: playerTime.sampleTime, nodeSampleRate: playerTime.sampleRate)
        else { return }
        currentTime = seconds
        refreshBufferedTime()
    }

    func startTimeUpdates() {
        timeTask?.cancel()
        timeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, state == .playing else { return }
                updateCurrentTime()
            }
        }
    }

    // MARK: Graph

    /// The player node's own sample timeline now, or nil before the first render.
    private func nodeSampleTime() -> Int64? {
        guard let node = _graph?.playerNode, let renderTime = node.lastRenderTime,
              renderTime.isSampleTimeValid || renderTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return nil }
        return playerTime.sampleTime
    }

    func record(_ diagnostic: ScheduleDiagnostic) {
        scheduleDiagnostics.append(diagnostic)
        if scheduleDiagnostics.count > 32 { scheduleDiagnostics.removeFirst() }
    }

    private func record(_ outcome: GaplessScheduler.CompletionOutcome) {
        completionDiagnostics.append(outcome)
        if completionDiagnostics.count > 32 { completionDiagnostics.removeFirst() }
    }

    /// Whether a following file is queued on the node (tests).
    var hasPreScheduledNext: Bool { scheduler.scheduledNextTrackID != nil }

    func ensureGraph() -> AudioGraph {
        if let _graph { return _graph }
        let graph = AudioGraph(volume: volume, balance: balance, eq: eq, analyzer: analyzer, outputDevices: outputDevices)
        _graph = graph
        configTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                guard let self, (note.object as AnyObject?) === self._graph?.engine else { continue }
                self.requestOutputReconfigure()
            }
        }
        // Started with the graph, so a player that never plays installs no CoreAudio listener.
        let changes = outputDevices.defaultOutputDeviceChanges()
        outputTask = Task { [weak self] in
            for await id in changes {
                guard let self else { break }
                self.outputDeviceChanged(to: id)
            }
        }
        return graph
    }

    func startedGraph() throws -> AudioGraph {
        let graph = ensureGraph()
        try graph.start()
        return graph
    }

    /// The system default output moved to another device. The engine keeps the device it was created on, so
    /// the graph remembers the new one and `reconfigureOutput()` rebinds it. No graph yet: the engine created
    /// later starts on the current default.
    func outputDeviceChanged(to id: AudioDeviceID) {
        guard let graph = _graph else { return }
        let info = outputDevices.describe(id)
        log.info("""
            default output changed: device \(id, privacy: .public) \(info?.name ?? "?", privacy: .public) \
            transport \(info?.transport ?? "?", privacy: .public) nominal \(info?.nominalSampleRate ?? 0, privacy: .public)
            """)
        graph.outputDevice = id
        requestOutputReconfigure()
    }

    /// Coalesces triggers: our device listener and the engine's own notification both fire for one switch,
    /// in either order, and land in the same turn as one restart. A later straggler repeats the idempotent
    /// handler (one more restart from the current position).
    func requestOutputReconfigure() {
        guard !outputReconfigurePending else { return }
        outputReconfigurePending = true
        Task { @MainActor [weak self] in
            self?.outputReconfigurePending = false
            self?.reconfigureOutput()
        }
    }

    /// The output device changed or the engine stopped itself: stop the engine, restart it through
    /// `AudioGraph.start()` (which binds the new device and reconnects at its rate) and reschedule from the
    /// current position, for a complete file and for a progressive one.
    func reconfigureOutput() {
        guard let graph = _graph else { return }
        // Read the position while the node still has a render time (the listener path leaves the engine running).
        if state == .playing { updateCurrentTime() }
        graph.stopEngine()   // also when the engine stopped itself already (no-op)
        if stream != nil {
            do {
                try graph.start()
                restartStreamAfterOutputChange(graph)   // the next chunk re-anchors at the new rate and latency
            } catch {
                fail(error)
            }
            return
        }
        // Stopped, or loading a complete file: nothing is scheduled; the next start() (play / begin) binds
        // and connects. A progressive track waiting for its preroll is the exception: its feeder is already
        // scheduling, and its first buffer would start a node whose engine has stopped.
        guard state != .stopped, state != .loading || progressive != nil else { return }
        let resumeTime = currentTime
        do {
            discardSchedule()
            graph.playerNode.stop()
            try graph.start()   // bind -> connectIfNeeded at the new rate -> analyzer
            if let progressive {
                // The feeder re-applies the client format itself: the output rate may have changed.
                isBuffering = false
                let frame = min(Int64(resumeTime * progressive.fileRate), max(progressive.lengthFrames - 1, 0))
                startFeeder(progressive, from: frame, preroll: state == .loading)
            } else if let file {
                let frame = AVAudioFramePosition(resumeTime * file.processingFormat.sampleRate)
                schedule(file, from: min(frame, max(file.length - 1, 0)))
                if state == .playing { graph.playerNode.play() }
                scheduleNextIfNeeded()
            }
            if state == .playing { emit(.seeked(resumeTime)) }
        } catch {
            fail(error)
        }
    }

    /// A track could not be resolved or opened. Winamp skips it and plays on; Webamp turns a media error
    /// into "ended". The player stops instead when the error says the whole source is down, when repeat is
    /// `.one` (the same track would fail again), or when every queued track has failed in a row (one pass).
    func trackFailed(_ error: any Error) {
        let sourceWide = (error as? any SourceScopedError)?.affectsWholeSource ?? false
        let count = consecutiveFailures + 1
        guard !sourceWide, queue.repeatMode != .one, count < queue.tracks.count,
              let failed = queue.current, queue.indexAfterCurrentEnds() != nil else {
            fail(error)
            return
        }
        consecutiveFailures = count
        let message = error.localizedDescription
        errorMessage = message
        emit(.failed(PlaybackFailure(track: failed, message: message, consecutiveFailures: count, skipped: true)))
        queue.advanceAfterTrackEnd()   // emits .trackChanged after .failed
        startCurrentTrack(autoplay: autoplayAfterLoad)
    }

    func fail(_ error: any Error) {
        consecutiveFailures += 1
        let failure = PlaybackFailure(
            track: queue.current, message: error.localizedDescription,
            consecutiveFailures: consecutiveFailures, skipped: false)
        stop()   // resets consecutiveFailures; the event above already captured it
        errorMessage = failure.message
        emit(.failed(failure))
    }
}

/// Identifies one registration made with `Player.addEventObserver(_:)`.
public struct PlayerEventToken: Hashable, Sendable {
    let id: UUID
}

/// Coarse player changes for observers that must not poll (Now Playing).
public enum PlayerEvent: Sendable {
    case trackChanged(Track?)
    case stateChanged(PlaybackState)
    case seeked(TimeInterval)
    case failed(PlaybackFailure)
    /// A server-timed stream took the node (`beginStream`).
    case streamStarted
    /// The stream stopped (`endStream`, or local transport preempting it).
    case streamEnded
    /// Local transport ended the stream; the bridge should tell the server to stop sending.
    case streamPreempted
}

/// One track that could not be resolved or opened, or an engine failure. `skipped` says the player moved on
/// to the next track; `consecutiveFailures` counts this run of failures (resets when a track opens or the
/// player stops), so a listener can say "3 tracks" when a whole pass failed.
public struct PlaybackFailure: Sendable, Equatable {
    public let track: Track?
    public let message: String
    public let consecutiveFailures: Int
    public let skipped: Bool

    public init(track: Track?, message: String, consecutiveFailures: Int, skipped: Bool) {
        self.track = track
        self.message = message
        self.consecutiveFailures = consecutiveFailures
        self.skipped = skipped
    }
}

/// One `scheduleSegment` call as seen on the player node's timeline (tests, #0055).
struct ScheduleDiagnostic: Sendable {
    let trackID: UUID
    let startFrame: Int64
    /// The node's sample time when the segment was queued; nil before the first render.
    let nodeSampleTimeAtSchedule: Int64?
    let nodeSampleRate: Double
    /// Seconds into the file where the segment starts (non-zero after a seek or a device change).
    let seekOffset: TimeInterval
    let wallClock = ContinuousClock.now

    /// Frames between "now" on the node and where this segment starts; nil if unknown.
    var leadFrames: Int64? { nodeSampleTimeAtSchedule.map { startFrame - $0 } }
    var leadMillis: Double? { leadFrames.map { Double($0) / nodeSampleRate * 1000 } }
}
