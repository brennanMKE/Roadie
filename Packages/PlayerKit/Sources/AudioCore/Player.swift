import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class Player: NowPlayingCommandTarget {
    public private(set) var queue = PlayQueue() {
        didSet { emitTrackChangeIfNeeded() }
    }
    public private(set) var state: PlaybackState = .stopped {
        didSet { emit(.stateChanged(state)) }
    }
    public private(set) var currentTime: TimeInterval = 0
    /// File format of the loaded track; nil while loading or stopped.
    public private(set) var currentFormat: PlaybackFormat?
    public private(set) var errorMessage: String?

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

    private func emit(_ event: PlayerEvent) {
        for observer in eventObservers { observer.handler(event) }
    }
    @ObservationIgnored private var lastEmittedTrackID: UUID?

    @ObservationIgnored private let resolver: any TrackResolver
    @ObservationIgnored var _graph: AudioGraph?
    /// Spectrum / oscilloscope source for the visualizer. Pull `latestFrame()` from the main
    /// thread at 30-60 Hz; it is installed on the mixer whenever the engine starts.
    @ObservationIgnored public let analyzer = AnalyzerTap()
    /// Test-only: when on, `schedule` and `segmentFinished` append to the capped diagnostic arrays below.
    @ObservationIgnored var recordsDiagnostics = false
    @ObservationIgnored private(set) var scheduleDiagnostics: [ScheduleDiagnostic] = []
    @ObservationIgnored private(set) var completionDiagnostics: [GaplessScheduler.CompletionOutcome] = []
    @ObservationIgnored private var file: AVAudioFile?
    /// The pre-scheduled file behind `file`, if any (its track is `scheduler.scheduledNextTrackID`).
    @ObservationIgnored private var nextFile: AVAudioFile?
    /// Decides which completion handlers are still valid and tracks the node's timeline.
    @ObservationIgnored private var scheduler = GaplessScheduler()
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// What the in-flight (or last) load should do when the file opens: play, or park paused.
    /// Play, pause and toggle flip it while `state == .loading`.
    @ObservationIgnored private(set) var autoplayAfterLoad = true
    @ObservationIgnored private var timeTask: Task<Void, Never>?
    @ObservationIgnored private var configTask: Task<Void, Never>?

    /// Construction does not touch the audio engine.
    public init(resolver: any TrackResolver = FileTrackResolver()) {
        self.resolver = resolver
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
        if removingCurrent && state != .stopped {
            // Keep the transport intent: a paused player parks on the new current track at 0:00,
            // and a load in flight keeps whatever play/pause intent it has accumulated.
            let autoplay = state == .loading ? autoplayAfterLoad : state == .playing
            if queue.current != nil { startCurrentTrack(autoplay: autoplay) } else { stop() }
        } else {
            reconcileSchedule()
        }
    }

    public func clearQueue() {
        stop()
        queue.removeAll()
    }

    // MARK: Transport

    public func play() {
        switch state {
        case .playing:
            return
        case .loading:
            // The load is already in flight; just make sure it plays when it lands.
            autoplayAfterLoad = true
        case .paused:
            do {
                let graph = try startedGraph()
                graph.playerNode.play()
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
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()
        _graph?.playerNode.stop()
        file = nil
        currentFormat = nil
        currentTime = 0
        state = .stopped
    }

    public func next() {
        currentTime = 0   // before the queue change publishes the new track
        if queue.next() != nil {
            startCurrentTrack()
        } else {
            stop()
        }
    }

    public func previous() {
        currentTime = 0   // before the queue change publishes the new track
        if queue.previous() != nil {
            startCurrentTrack()
        } else if queue.current != nil {
            startCurrentTrack()   // restart the current track
        }
    }

    public func seek(to seconds: TimeInterval) {
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
    private func startCurrentTrack(autoplay: Bool = true) {
        guard let track = queue.current else {
            stop()
            return
        }
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()   // bumps the generation: any older load is now stale
        _graph?.playerNode.stop()
        file = nil   // seek / reschedule / device change must not act on the previous track's file
        currentFormat = nil
        currentTime = 0
        errorMessage = nil
        autoplayAfterLoad = autoplay
        state = .loading   // synchronous: observers and a repeated Play see the load immediately
        let generation = scheduler.generation
        let resolver = self.resolver
        loadTask = Task {
            do {
                let url = try await resolver.localURL(for: track)
                guard !Task.isCancelled, scheduler.generation == generation else { return }
                let file = try AVAudioFile(forReading: url)
                try begin(file)
            } catch {
                guard !Task.isCancelled, scheduler.generation == generation else { return }
                fail(error)
            }
        }
    }

    private static func format(of file: AVAudioFile) -> PlaybackFormat {
        PlaybackFormat(sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount))
    }

    private func begin(_ file: AVAudioFile) throws {
        let graph = ensureGraph()
        discardSchedule()
        graph.playerNode.stop()
        try graph.start()
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
                nodeSampleRate: nodeRate))
        }
        graph.playerNode.scheduleSegment(
            file, startingFrame: frame, frameCount: AVAudioFrameCount(clamping: remaining), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentFinished(token) }
        }
    }

    /// Invalidate before every `playerNode.stop()`: stop fires the handler of each discarded item.
    private func discardSchedule() {
        preloadTask?.cancel()
        scheduler.invalidate()
        nextFile = nil
    }

    /// Queue the track that follows the current one behind it so the node never goes silent.
    private func scheduleNextIfNeeded() {
        preloadTask?.cancel()
        guard state == .playing || state == .paused, scheduler.items.count == 1,
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
        guard state != .stopped, let file, let graph = _graph else { return }
        let queueNext = queue.indexAfterCurrentEnds().map { queue.tracks[$0].id }
        switch SchedulingDecision.reconcile(queueNext: queueNext, scheduledNext: scheduler.scheduledNextTrackID) {
        case .keep:
            break
        case .scheduleNext:
            scheduleNextIfNeeded()
        case .restartCurrent:
            if state == .playing { updateCurrentTime() }
            let rate = file.processingFormat.sampleRate
            let frame = min(AVAudioFramePosition(currentTime * rate), max(file.length - 1, 0))
            discardSchedule()
            graph.playerNode.stop()
            schedule(file, from: frame)
            if state == .playing { graph.playerNode.play() }
            scheduleNextIfNeeded()
        }
    }

    private func segmentFinished(_ token: ScheduleToken) {
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
            currentFormat = Self.format(of: next)
            nextFile = nil
            scheduleNextIfNeeded()
        case .reachedEnd:
            trackEnded()
        }
    }

    /// The current track finished with nothing pre-scheduled behind it.
    private func trackEnded() {
        currentTime = 0
        if queue.advanceAfterTrackEnd() != nil {
            startCurrentTrack()
        } else {
            stop()
        }
    }

    // MARK: Time

    private func updateCurrentTime() {
        guard file != nil, let node = _graph?.playerNode,
              let renderTime = node.lastRenderTime,
              // Invalid before the first render (offline mode, or just after a restart); passing it
              // to playerTime(forNodeTime:) raises an Objective-C exception.
              renderTime.isSampleTimeValid || renderTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime),
              let seconds = scheduler.position(
                atNodeSampleTime: playerTime.sampleTime, nodeSampleRate: playerTime.sampleRate)
        else { return }
        currentTime = seconds
    }

    private func startTimeUpdates() {
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

    private func record(_ diagnostic: ScheduleDiagnostic) {
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
        let graph = AudioGraph(volume: volume, balance: balance, eq: eq, analyzer: analyzer)
        _graph = graph
        configTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                guard let self, (note.object as AnyObject?) === self._graph?.engine else { continue }
                self.handleConfigurationChange()
            }
        }
        return graph
    }

    private func startedGraph() throws -> AudioGraph {
        let graph = ensureGraph()
        try graph.start()
        return graph
    }

    /// The output device changed and the engine stopped itself.
    private func handleConfigurationChange() {
        // Nothing is scheduled while stopped or loading; the load connects and starts the engine itself.
        guard let graph = _graph, state != .stopped, state != .loading else { return }
        let resumeTime = currentTime
        do {
            discardSchedule()
            graph.playerNode.stop()
            try graph.start()
            if let file {
                let frame = AVAudioFramePosition(resumeTime * file.processingFormat.sampleRate)
                schedule(file, from: min(frame, max(file.length - 1, 0)))
                if state == .playing { graph.playerNode.play() }
                scheduleNextIfNeeded()
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        let message = error.localizedDescription
        stop()
        errorMessage = message
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
}

/// One `scheduleSegment` call as seen on the player node's timeline (tests, #0055).
struct ScheduleDiagnostic: Sendable {
    let trackID: UUID
    let startFrame: Int64
    /// The node's sample time when the segment was queued; nil before the first render.
    let nodeSampleTimeAtSchedule: Int64?
    let nodeSampleRate: Double
    let wallClock = ContinuousClock.now

    /// Frames between "now" on the node and where this segment starts; nil if unknown.
    var leadFrames: Int64? { nodeSampleTimeAtSchedule.map { startFrame - $0 } }
    var leadMillis: Double? { leadFrames.map { Double($0) / nodeSampleRate * 1000 } }
}
