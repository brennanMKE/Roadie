import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "co.sstools.roadie", category: "AudioStream")

/// A server-timed PCM stream on the player node (#0106): the server owns the queue and stamps each chunk
/// with the local time its first frame must be heard. Never touches the local queue or the gapless scheduler.
@MainActor
final class StreamSession {
    var format: StreamFormat
    var decoder: PCMStreamDecoder
    var timeline = StreamTimeline()
    var corrector = StreamDriftCorrector()
    /// Bumped before every `playerNode.stop()`; completions from an older generation are ignored.
    var generation = 0
    var pendingBuffers = 0
    /// Node frames scheduled since the last start.
    var scheduledNodeFrames: Int64 = 0
    /// Seconds of stream time skipped (drop, +) or repeated (duplicate, −) by corrections the node has reached.
    var appliedSkew: Double = 0
    /// Corrections not yet reached by the node: (node frame where it takes effect, skew delta).
    var pendingCorrections: [(frame: Int64, skew: Double)] = []
    /// The last measured sync error (µs), for logs and tests.
    var lastErrorMicros: Int64?
    /// Underruns seen (the node played everything scheduled before the next chunk). Cumulative; diagnostic.
    var underruns = 0

    init(format: StreamFormat, decoder: PCMStreamDecoder) {
        self.format = format
        self.decoder = decoder
    }

    func resetPosition() {
        scheduledNodeFrames = 0
        appliedSkew = 0
        pendingCorrections = []
        pendingBuffers = 0
        lastErrorMicros = nil
    }
}

extension Player {
    public var isStreaming: Bool { stream != nil }

    /// The rate the graph runs at (the output's), for the hello's single supported format. Starts no engine.
    public var streamOutputSampleRate: Double {
        if let rate = _graph?.processingSampleRate { return rate }
        return ensureGraph().outputSampleRate()
    }

    /// Takes the node from file playback (the local queue is kept) and waits for the first chunk.
    public func beginStream(_ format: StreamFormat) throws {
        if stream != nil {
            changeStreamFormat(format)
            return
        }
        loadTask?.cancel()
        timeTask?.cancel()
        discardSchedule()   // a file completion firing after the stop below is stale
        _graph?.playerNode.stop()
        file = nil
        closeProgressive()
        let graph = try startedGraph()
        let rate = graph.processingSampleRate ?? graph.outputSampleRate()
        guard let decoder = PCMStreamDecoder(format: format, nodeRate: rate) else {
            throw AudioCoreError.unsupportedStreamFormat
        }
        streamLatencySeconds = currentOutputLatency(graph)
        stream = StreamSession(format: format, decoder: decoder)
        consecutiveFailures = 0
        errorMessage = nil
        currentFormat = PlaybackFormat(sampleRate: format.sampleRate, channels: format.channels)
        currentTime = 0
        state = .loading
        log.info("stream began: \(format.sampleRate, privacy: .public) Hz \(format.channels, privacy: .public) ch \(format.bitDepth, privacy: .public) bit, node \(rate, privacy: .public) Hz")
        emit(.streamStarted)
    }

    /// stream/start during a stream: same timeline, new decoder.
    public func changeStreamFormat(_ format: StreamFormat) {
        guard let session = stream, let rate = _graph?.processingSampleRate,
              let decoder = PCMStreamDecoder(format: format, nodeRate: rate) else { return }
        session.format = format
        session.decoder = decoder
        currentFormat = PlaybackFormat(sampleRate: format.sampleRate, channels: format.channels)
    }

    public func appendStream(_ chunk: StreamChunk) {
        guard let session = stream, let graph = _graph, let nodeRate = graph.processingSampleRate else { return }
        let frames = session.format.frameCount(of: chunk.pcm)
        guard frames > 0 else { return }
        let rate = session.format.sampleRate
        let now = streamRenderClock.nowMicros() + Int64((streamLatencySeconds * 1e6).rounded())
        // Underrun (#0112): the node played past everything scheduled, so its sample clock no longer maps to
        // stream time. Re-anchor so this chunk plays at its presentation time.
        if session.timeline.anchorMicros != nil, session.scheduledNodeFrames > 0,
           let played = streamPlayerSample(graph), played.sample >= session.scheduledNodeFrames {
            session.underruns += 1
            log.notice("stream underrun at node frame \(played.sample, privacy: .public): re-anchoring")
            session.timeline.reset()
        }
        switch session.timeline.place(chunk.presentationMicros, frames: frames, nowMicros: now, rate: rate) {
        case .late:
            log.debug("stream chunk late, dropped (\(session.timeline.lateChunks, privacy: .public) so far)")
        case .start(let at, let drop):
            startStream(session, graph: graph, pcm: chunk.pcm, at: at, dropLeading: drop, nodeRate: nodeRate)
        case .gap(_, let silenceMicros):
            if silenceMicros <= session.timeline.policy.snapMicros {
                log.info("stream gap of \(silenceMicros, privacy: .public) µs, filled with silence")
                let silenceFrames = AVAudioFrameCount(max(0, Double(silenceMicros) * nodeRate / 1e6).rounded())
                if silenceFrames > 0, let silence = AVAudioPCMBuffer(pcmFormat: session.decoder.outputFormat, frameCapacity: silenceFrames) {
                    silence.frameLength = silenceFrames   // zero-filled
                    scheduleStreamBuffer(silence, session: session, graph: graph)
                }
                if let buffer = session.decoder.decode(chunk.pcm) { scheduleStreamBuffer(buffer, session: session, graph: graph) }
            } else {
                // Long gap (#0112): no silence buffer; schedule the chunk at its own node sample.
                let startFrame = session.scheduledNodeFrames + Int64((Double(silenceMicros) * nodeRate / 1e6).rounded())
                log.notice("stream gap of \(silenceMicros, privacy: .public) µs: re-anchored at node frame \(startFrame, privacy: .public)")
                if let buffer = session.decoder.decode(chunk.pcm) {
                    scheduleStreamBuffer(buffer, session: session, graph: graph,
                                         at: AVAudioTime(sampleTime: startFrame, atRate: nodeRate), startFrame: startFrame)
                }
            }
        case .overlap(let drop):
            if let buffer = session.decoder.decode(chunk.pcm, dropLeading: drop) {
                scheduleStreamBuffer(buffer, session: session, graph: graph)
            }
        case .contiguous:
            var drop = 0
            var duplicate = 0
            if let error = streamErrorMicros(session, graph: graph, nodeRate: nodeRate) {
                switch session.corrector.correction(errorMicros: error, chunkFrames: frames, rate: rate) {
                case .none: break
                case .drop(let n): drop = n
                case .duplicate(let n): duplicate = n
                case .snap:
                    log.notice("stream sync error \(error, privacy: .public) µs: re-anchoring")
                    session.timeline.reset()
                    if case .start(let at, let d) = session.timeline.place(
                        chunk.presentationMicros, frames: frames, nowMicros: now, rate: rate) {
                        startStream(session, graph: graph, pcm: chunk.pcm, at: at, dropLeading: d, nodeRate: nodeRate)
                    }
                    return
                }
            }
            guard let buffer = session.decoder.decode(chunk.pcm, dropLeading: drop, duplicateLast: duplicate) else { return }
            if drop != duplicate {
                session.pendingCorrections.append((session.scheduledNodeFrames, Double(drop - duplicate) / rate))
            }
            scheduleStreamBuffer(buffer, session: session, graph: graph)
        }
    }

    /// stream/clear: drop scheduled audio; the next chunk re-anchors. The stream continues.
    public func clearStream() {
        guard let session = stream else { return }
        session.generation &+= 1
        _graph?.playerNode.stop()
        session.timeline.reset()
        session.decoder.reset()
        session.resetPosition()
    }

    /// stream/end: stop; the local queue is untouched.
    public func endStream() {
        guard let session = stream else { return }
        session.generation &+= 1
        stream = nil
        timeTask?.cancel()
        _graph?.playerNode.stop()
        currentFormat = nil
        currentTime = 0
        state = .stopped
        log.info("stream ended")
        emit(.streamEnded)
    }

    /// Local transport while streaming: end the stream and tell observers it was preempted. Returns whether it did.
    @discardableResult
    func preemptStreamIfNeeded() -> Bool {
        guard stream != nil else { return false }
        endStream()
        emit(.streamPreempted)
        return true
    }

    // MARK: Internals

    private func startStream(
        _ session: StreamSession, graph: AudioGraph, pcm: Data, at: Int64, dropLeading: Int, nodeRate: Double
    ) {
        session.generation &+= 1
        graph.playerNode.stop()
        session.decoder.reset()
        session.resetPosition()
        guard let buffer = session.decoder.decode(pcm, dropLeading: dropLeading) else { return }
        scheduleStreamBuffer(buffer, session: session, graph: graph)
        let when = streamRenderClock.startTime(
            forOutputMicros: at, latencySeconds: streamLatencySeconds, nodeRate: nodeRate)
        graph.playerNode.play(at: when)
        if state != .playing { state = .playing }
        startTimeUpdates()
    }

    private func scheduleStreamBuffer(
        _ buffer: AVAudioPCMBuffer, session: StreamSession, graph: AudioGraph,
        at time: AVAudioTime? = nil, startFrame: Int64? = nil
    ) {
        let generation = session.generation
        session.pendingBuffers += 1
        session.scheduledNodeFrames = (startFrame ?? session.scheduledNodeFrames) + Int64(buffer.frameLength)
        graph.playerNode.scheduleBuffer(buffer, at: time, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.streamBufferFinished(generation) }
        }
    }

    private func streamBufferFinished(_ generation: Int) {
        guard let session = stream, session.generation == generation else { return }
        session.pendingBuffers -= 1
        if session.pendingBuffers <= 0, state == .playing {
            log.notice("stream underrun: no audio scheduled")
        }
    }

    /// The node's played position since the last start (node frames), or nil before it starts.
    private func streamPlayerSample(_ graph: AudioGraph) -> (sample: Int64, renderTime: AVAudioTime)? {
        let node = graph.playerNode
        guard let renderTime = node.lastRenderTime,
              renderTime.isSampleTimeValid || renderTime.isHostTimeValid,
              let playerTime = node.playerTime(forNodeTime: renderTime),
              playerTime.sampleTime >= 0 else { return nil }
        return (playerTime.sampleTime, renderTime)
    }

    /// Output time of the frame being rendered minus its stamped time, net of corrections still in flight.
    func streamErrorMicros(_ session: StreamSession, graph: AudioGraph, nodeRate: Double) -> Int64? {
        guard let anchor = session.timeline.anchorMicros, let played = streamPlayerSample(graph),
              let output = streamRenderClock.outputMicros(of: played.renderTime, latencySeconds: streamLatencySeconds)
        else { return nil }
        let sample = played.sample
        while let first = session.pendingCorrections.first, first.frame <= sample {
            session.appliedSkew += first.skew
            session.pendingCorrections.removeFirst()
        }
        let stamped = anchor + Int64(((Double(sample) / nodeRate + session.appliedSkew) * 1e6).rounded())
        let error = output - stamped
        session.lastErrorMicros = error
        let pending = session.pendingCorrections.reduce(0) { $0 + $1.skew }
        return error - Int64((pending * 1e6).rounded())
    }

    func updateStreamTime() {
        guard let graph = _graph, let rate = graph.processingSampleRate,
              let played = streamPlayerSample(graph) else { return }
        currentTime = Double(played.sample) / rate
    }

    /// Output latency to add to render times: presentation latency plus the device's latency and safety
    /// offset. Zero in manual rendering (no device).
    func currentOutputLatency(_ graph: AudioGraph) -> Double {
        guard !graph.engine.isInManualRenderingMode else { return 0 }
        var latency = graph.engine.outputNode.presentationLatency
        if let device = graph.outputDevice ?? outputDevices.defaultOutputDevice(),
           let info = outputDevices.describe(device) {
            latency += info.latencySeconds
        }
        return max(latency, 0)
    }

    /// The output changed under a stream: the engine was restarted at the (maybe new) rate; rebuild the
    /// decoder and re-anchor on the next chunk with the new latency.
    func restartStreamAfterOutputChange(_ graph: AudioGraph) {
        guard let session = stream else { return }
        clearStream()
        if let rate = graph.processingSampleRate,
           let decoder = PCMStreamDecoder(format: session.format, nodeRate: rate) {
            session.decoder = decoder
        }
        streamLatencySeconds = currentOutputLatency(graph)
    }
}
