import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class Player {
    public private(set) var queue = PlayQueue()
    public private(set) var state: PlaybackState = .stopped
    public private(set) var currentTime: TimeInterval = 0
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

    @ObservationIgnored private let resolver: any TrackResolver
    @ObservationIgnored var _graph: AudioGraph?
    @ObservationIgnored private var file: AVAudioFile?
    /// The pre-scheduled file behind `file`, if any (its track is `scheduler.scheduledNextTrackID`).
    @ObservationIgnored private var nextFile: AVAudioFile?
    /// Decides which completion handlers are still valid and tracks the node's timeline.
    @ObservationIgnored private var scheduler = GaplessScheduler()
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeTask: Task<Void, Never>?
    @ObservationIgnored private var configTask: Task<Void, Never>?

    /// Construction does not touch the audio engine.
    public init(resolver: any TrackResolver = FileTrackResolver()) {
        self.resolver = resolver
    }

    // MARK: Queue

    public func enqueue(_ tracks: [Track]) {
        queue.append(tracks)
        reconcileSchedule()
    }

    public func removeTrack(at index: Int) {
        let removingCurrent = queue.currentIndex == index
        queue.remove(at: index)
        if removingCurrent && state != .stopped {
            if queue.current != nil { startCurrentTrack() } else { stop() }
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
        queue.select(index)
        startCurrentTrack()
    }

    public func pause() {
        guard state == .playing else { return }
        updateCurrentTime()
        _graph?.playerNode.pause()
        timeTask?.cancel()
        state = .paused
    }

    public func togglePause() {
        switch state {
        case .playing: pause()
        case .paused: play()
        case .stopped: play()
        }
    }

    public func stop() {
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()
        _graph?.playerNode.stop()
        file = nil
        currentTime = 0
        state = .stopped
    }

    public func next() {
        if queue.next() != nil {
            startCurrentTrack()
        } else {
            stop()
        }
    }

    public func previous() {
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
    }

    // MARK: Starting tracks

    private func startCurrentTrack() {
        guard let track = queue.current else {
            stop()
            return
        }
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()
        _graph?.playerNode.stop()
        errorMessage = nil
        let resolver = self.resolver
        loadTask = Task {
            do {
                let url = try await resolver.localURL(for: track)
                guard !Task.isCancelled, queue.current?.id == track.id else { return }
                let file = try AVAudioFile(forReading: url)
                try begin(file)
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func begin(_ file: AVAudioFile) throws {
        let graph = ensureGraph()
        discardSchedule()
        graph.playerNode.stop()
        graph.connect(format: file.processingFormat)
        try graph.start()
        self.file = file
        schedule(file, from: 0)
        currentTime = 0
        graph.playerNode.play()
        state = .playing
        startTimeUpdates()
        scheduleNextIfNeeded()
    }

    /// Every schedule call goes through here so the scheduler's bookkeeping matches the node.
    /// `at: nil` queues the segment right behind whatever is already scheduled.
    private func schedule(
        _ file: AVAudioFile, trackID: UUID? = nil, from frame: AVAudioFramePosition = 0
    ) {
        guard let graph = _graph, let id = trackID ?? queue.current?.id else { return }
        let remaining = file.length - frame
        guard remaining > 0 else { return }
        let item = scheduler.append(trackID: id, frameLength: remaining, seekOffsetFrames: frame)
        let token = item.token
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
        guard state != .stopped, scheduler.items.count == 1,
              let index = queue.indexAfterCurrentEnds() else { return }
        let track = queue.tracks[index]
        let generation = scheduler.generation
        let resolver = self.resolver
        preloadTask = Task {
            guard let url = try? await resolver.localURL(for: track),
                  !Task.isCancelled, scheduler.generation == generation, scheduler.items.count == 1,
                  let current = queue.indexAfterCurrentEnds(), queue.tracks[current].id == track.id,
                  let graph = _graph, let connected = graph.connectedFormat,
                  let next = try? AVAudioFile(forReading: url) else { return }
            // A format change needs a reconnect; leave it to the normal (gapped) path.
            let policy = FormatPolicy.compare(
                current: AudioFormatDescriptor(sampleRate: connected.sampleRate, channelCount: connected.channelCount),
                next: AudioFormatDescriptor(
                    sampleRate: next.processingFormat.sampleRate, channelCount: next.processingFormat.channelCount))
            guard policy == .gapless else { return }
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
        switch scheduler.complete(token) {
        case .stale:
            break
        case .advanced(let id):
            // The node has already moved on to the pre-scheduled file; follow it.
            guard queue.advanceAfterTrackEnd() != nil, queue.current?.id == id, let next = nextFile else {
                startCurrentTrack()
                return
            }
            file = next
            nextFile = nil
            currentTime = 0
            scheduleNextIfNeeded()
        case .reachedEnd:
            trackEnded()
        }
    }

    /// The current track finished with nothing pre-scheduled behind it.
    private func trackEnded() {
        if queue.advanceAfterTrackEnd() != nil {
            startCurrentTrack()
        } else {
            stop()
        }
    }

    // MARK: Time

    private func updateCurrentTime() {
        guard let file, let node = _graph?.playerNode,
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime),
              let seconds = scheduler.position(
                atNodeSampleTime: playerTime.sampleTime, sampleRate: file.processingFormat.sampleRate)
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

    /// Whether a following file is queued on the node (tests).
    var hasPreScheduledNext: Bool { scheduler.scheduledNextTrackID != nil }

    func ensureGraph() -> AudioGraph {
        if let _graph { return _graph }
        let graph = AudioGraph(volume: volume, balance: balance)
        _graph = graph
        configTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                self?.handleConfigurationChange()
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
        guard let graph = _graph, state != .stopped else { return }
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
