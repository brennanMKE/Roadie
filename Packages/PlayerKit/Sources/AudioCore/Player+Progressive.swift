import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "Progressive")

/// The current track playing from a download still in flight (#0039): its reader, and the feeder that keeps
/// the player node supplied with decoded buffers. The reader outlives feeders (a seek starts a new one).
@MainActor
final class ProgressiveSession {
    let reader: ProgressiveAudioReader
    let prerollBytes: Int64
    var feeder: ProgressiveFeeder?
    /// Bumped for every feeder; events from an older one are ignored.
    var feederGeneration = 0
    /// The scheduler item the current feeder fills (its length is corrected when the decoder ends).
    var scheduleToken: ScheduleToken?
    var hasScheduledLastBuffer = false

    init(reader: ProgressiveAudioReader, prerollBytes: Int64) {
        self.reader = reader
        self.prerollBytes = prerollBytes
    }

    var fileRate: Double { reader.fileSampleRate }
    var lengthFrames: Int64 { reader.lengthFrames }
}

extension Player {
    /// Whether the current track plays from a progressive source (tests).
    var usesProgressiveSource: Bool { progressive != nil }

    // MARK: Opening

    /// Parses the header while the download continues. Falls back to the whole-file path for containers that
    /// cannot be read while arriving; any other failure is the track's.
    func openProgressive(_ source: any ProgressiveByteSource, track: Track, generation: UInt64) async throws {
        let reader: ProgressiveAudioReader
        do {
            reader = try await ProgressiveAudioReader.open(source, policy: progressivePolicy)
        } catch let error as ProgressiveError where error.isFallbackTrigger {
            try await fallBackToFile(track: track, reader: nil, source: source, generation: generation, reason: error)
            return
        } catch {
            source.close()
            throw error
        }
        guard !Task.isCancelled, scheduler.generation == generation else {
            reader.close()
            return
        }
        do {
            try await beginProgressive(reader, track: track)
        } catch let error as ProgressiveError where error.isFallbackTrigger {
            try await fallBackToFile(track: track, reader: reader, source: source, generation: generation, reason: error)
        } catch {
            reader.close()
            throw error
        }
    }

    /// Joins the download already in flight (a source whose download is shared joins it), then lets the source go
    /// and opens the finished file. The join comes first: closing the source first could abandon the
    /// download and restart it.
    private func fallBackToFile(
        track: Track, reader: ProgressiveAudioReader?, source: any ProgressiveByteSource, generation: UInt64,
        reason: ProgressiveError
    ) async throws {
        log.info("not streamable, playing the whole file: \(String(describing: reason), privacy: .public)")
        let url: URL
        do {
            url = try await resolver.localURL(for: track)
        } catch {
            if let reader { reader.close() } else { source.close() }
            throw error
        }
        if let reader { reader.close() } else { source.close() }
        guard !Task.isCancelled else { return }
        try begin(try AVAudioFile(forReading: url))
    }

    private func beginProgressive(_ reader: ProgressiveAudioReader, track: Track) async throws {
        let graph = ensureGraph()
        discardSchedule()
        graph.playerNode.stop()
        try graph.start()
        guard let format = graph.processingFormat else { throw ProgressiveError.formatUnsupported }
        let generation = scheduler.generation
        try await reader.setClientFormat(format.streamDescription.pointee)
        guard !Task.isCancelled, scheduler.generation == generation else {
            reader.close()
            return
        }
        // A device change while the client format was being set stopped the engine (and `.loading` made
        // `reconfigureOutput` skip it): start it again, at the new rate. The feeder applies the
        // graph's format itself, so a changed rate is picked up there.
        try graph.start()
        errorMessage = nil
        consecutiveFailures = 0
        let source = reader.source
        let session = ProgressiveSession(
            reader: reader,
            prerollBytes: progressivePolicy.prerollBytes(bitrateKbps: track.bitrate, finalSize: source.finalSize))
        file = nil
        progressive = session
        currentFormat = PlaybackFormat(sampleRate: reader.fileSampleRate, channels: reader.fileChannels)
        currentTime = 0
        startFeeder(session, from: 0, preroll: true)
    }

    // MARK: Feeding

    /// Queues one scheduler item for the rest of the track and starts a feeder that fills it.
    func startFeeder(_ session: ProgressiveSession, from frame: Int64, preroll: Bool) {
        guard let graph = _graph, let format = graph.processingFormat, let id = queue.current?.id else { return }
        let remaining = session.lengthFrames - frame
        guard remaining > 0 else {
            trackEnded()
            return
        }
        let nodeRate = format.sampleRate
        let item = scheduler.append(
            trackID: id,
            frameLength: GaplessScheduler.nodeFrames(
                fileFrames: remaining, fileSampleRate: session.fileRate, nodeSampleRate: nodeRate),
            seekOffset: Double(frame) / session.fileRate)
        if recordsDiagnostics {
            record(ScheduleDiagnostic(
                trackID: id, startFrame: item.startFrame, nodeSampleTimeAtSchedule: nil, nodeSampleRate: nodeRate,
                seekOffset: item.seekOffset))
        }
        session.feederGeneration += 1
        let generation = session.feederGeneration
        let token = item.token
        session.scheduleToken = token
        session.hasScheduledLastBuffer = false
        let feeder = ProgressiveFeeder(
            reader: session.reader, node: graph.playerNode, format: format, startFrame: frame,
            prerollBytes: preroll ? session.prerollBytes : 0, bufferFrames: progressiveBufferFrames,
            events: { [weak self, weak session] event in
                Task { @MainActor in
                    guard let self, let session else { return }
                    self.feederEvent(event, session: session, generation: generation)
                }
            },
            finished: { [weak self] in
                Task { @MainActor in self?.segmentFinished(token) }
            })
        session.feeder = feeder
        feeder.start()
    }

    private func feederEvent(_ event: ProgressiveFeederEvent, session: ProgressiveSession, generation: Int) {
        guard progressive === session, session.feederGeneration == generation, state != .stopped else { return }
        switch event {
        case .started:
            if state == .loading {
                errorMessage = nil
                if autoplayAfterLoad {
                    _graph?.playerNode.play()
                    state = .playing
                    startTimeUpdates()
                } else {
                    // Parked: the buffers stay queued on the stopped node; `play()` resumes them from the start.
                    state = .paused
                }
            } else if state == .playing, !isBuffering {
                _graph?.playerNode.play()
            }
            refreshBufferedTime()
        case .stalled:
            // The node's own timeline stops with it, so the scheduler's position stays right.
            if state == .playing {
                updateCurrentTime()
                _graph?.playerNode.pause()
            }
            isBuffering = true
            log.debug("buffering")
        case .resumed:
            isBuffering = false
            if state == .playing { _graph?.playerNode.play() }
            log.debug("resumed")
        case .reachedEnd(let frames):
            if let token = session.scheduleToken { scheduler.adjustLength(of: token, to: frames) }
        case .scheduledLast:
            session.hasScheduledLastBuffer = true
            scheduleNextIfNeeded()
        case .failed(let error):
            guard !(error is CancellationError) else { return }
            closeProgressive()
            trackFailed(error)
        }
    }

    // MARK: Seeking

    func seekProgressive(_ session: ProgressiveSession, to seconds: TimeInterval) {
        guard _graph != nil else { return }
        let rate = session.fileRate
        let requested = min(max(seconds, 0), Double(session.lengthFrames) / rate)
        guard Int64(requested * rate) < session.lengthFrames else {
            trackEnded()
            return
        }
        // Playback cannot start beyond the bytes that have arrived; the seek lands at the edge instead.
        let reachable = Double(session.reader.bufferedFrames()) / rate
        let target = min(requested, reachable)
        restartProgressive(session, at: Int64(target * rate))
        currentTime = target
        refreshBufferedTime()
        emit(.seeked(target))
    }

    func restartProgressive(_ session: ProgressiveSession, at frame: Int64) {
        guard let graph = _graph else { return }
        discardSchedule()   // cancels the feeder before the node stops
        graph.playerNode.stop()
        isBuffering = false
        startFeeder(session, from: frame, preroll: false)
    }

    func refreshBufferedTime() {
        let value = progressive.map { Double($0.reader.bufferedFrames()) / $0.fileRate }
        if bufferedTime != value { bufferedTime = value }
    }

    // MARK: Teardown

    /// Drops the progressive session: cancels the feeder and closes the reader (which closes the source, so
    /// the cache can abandon an unpinned download). Never blocks.
    func closeProgressive() {
        if isBuffering { isBuffering = false }
        if bufferedTime != nil { bufferedTime = nil }
        guard let session = progressive else { return }
        session.feeder?.cancel()
        session.feeder = nil
        session.reader.close()
        progressive = nil
    }
}
