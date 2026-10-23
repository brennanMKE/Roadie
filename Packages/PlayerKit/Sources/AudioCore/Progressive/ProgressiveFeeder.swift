import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "co.sstools.roadie", category: "Progressive")

/// What a feeder tells the player, from the feeder's own thread. The player hops to the main actor and
/// ignores events from a feeder that is no longer current.
enum ProgressiveFeederEvent: Sendable {
    /// The first buffer is on the node.
    case started
    /// The node ran out of audio and the reader is waiting for bytes.
    case stalled
    /// Audio is flowing again after a stall.
    case resumed
    /// The decoder hit the end. `framesProduced` is what this feeder decoded, in node-rate frames.
    case reachedEnd(framesProduced: Int64)
    /// The last buffer is queued; the next track can be pre-scheduled behind it.
    case scheduledLast
    case failed(any Error)
}

/// Keeps the player node fed with decoded PCM for one progressive track, on its own thread. It holds the
/// reader for its whole session (a restarted feeder starts only after the previous one let go), waits for a
/// short preroll, then decodes one buffer at a time and keeps at most `windowBuffers` queued ahead of the
/// node. The last buffer carries the `.dataPlayedBack` completion that advances the queue, exactly like a
/// file segment's.
final class ProgressiveFeeder: @unchecked Sendable {
    typealias Events = @Sendable (ProgressiveFeederEvent) -> Void

    private let reader: ProgressiveAudioReader
    private let node: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let clientDescription: AudioStreamBasicDescription
    private let startFrame: Int64
    private let prerollBytes: Int64
    private let bufferFrames: AVAudioFrameCount
    private let windowBuffers: Int
    private let events: Events
    private let finished: @Sendable () -> Void

    private let cond = NSCondition()
    private var outstanding = 0
    private var cancelled = false
    private var stalled = false
    private var started = false
    private var waitingForBytes = false
    private var scheduledFrames: Int64 = 0
    private var scheduledLast = false

    init(
        reader: ProgressiveAudioReader, node: AVAudioPlayerNode, format: AVAudioFormat, startFrame: Int64,
        prerollBytes: Int64, bufferFrames: AVAudioFrameCount? = nil, windowBuffers: Int = 8,
        events: @escaping Events, finished: @escaping @Sendable () -> Void
    ) {
        self.reader = reader
        self.node = node
        self.format = format
        self.clientDescription = format.streamDescription.pointee
        self.startFrame = startFrame
        self.prerollBytes = prerollBytes
        self.bufferFrames = bufferFrames ?? AVAudioFrameCount(max(format.sampleRate, 1024))
        self.windowBuffers = max(windowBuffers, 1)
        self.events = events
        self.finished = finished
    }

    // MARK: Diagnostics (tests, Player)

    /// The feeder is blocked on bytes that have not arrived (preroll or mid-decode).
    var isWaitingForBytes: Bool { cond.withLock { waitingForBytes } }
    var framesScheduled: Int64 { cond.withLock { scheduledFrames } }
    var hasScheduledLastBuffer: Bool { cond.withLock { scheduledLast } }

    // MARK: Lifecycle

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "SkinAmp.progressive-feeder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops feeding and wakes a read blocked on bytes. Late completions of buffers already on the node are
    /// harmless: the player ignores them through the scheduler's generation.
    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
        reader.interrupt()
    }

    private var isCancelled: Bool { cond.withLock { cancelled } }

    private func run() {
        reader.session {
            guard !isCancelled else { return }
            reader.beginSessionLocked()
            reader.setWaitingHandler { [weak self] in self?.readerIsWaiting() }
            defer { reader.setWaitingHandler(nil) }
            do {
                try feed()
            } catch {
                guard !isCancelled else { return }
                if !(error is CancellationError) { log.debug("feeder failed: \(String(describing: type(of: error)), privacy: .public)") }
                events(.failed(error))
            }
        }
    }

    // MARK: The loop

    private func feed() throws {
        try reader.applyClientFormatLocked(clientDescription)
        try waitForPreroll()
        guard !isCancelled else { return }
        try reader.calibratePositionUnitsLocked()
        try reader.seekLocked(toFrame: startFrame)

        var produced: Int64 = 0
        while true {
            cond.lock()
            while outstanding >= windowBuffers && !cancelled { cond.wait(until: Date().addingTimeInterval(0.1)) }
            let stop = cancelled
            cond.unlock()
            if stop { return }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames) else {
                throw ProgressiveError.formatUnsupported
            }
            let frames = try readTracked(into: buffer)
            if isCancelled { return }

            if frames == bufferFrames {
                produced += Int64(frames)
                try schedule(buffer, last: false)
                continue
            }
            if frames == 0 {
                // Ended exactly on a buffer boundary, so nothing marks the previous buffer as the last.
                // One silent frame carries the completion; it adds 23 microseconds at 44.1 kHz.
                Self.silence(buffer)
                buffer.frameLength = 1
                produced += 1
            } else {
                produced += Int64(frames)
            }
            events(.reachedEnd(framesProduced: produced))
            try schedule(buffer, last: true)
            events(.scheduledLast)
            return
        }
    }

    private func waitForPreroll() throws {
        let source = reader.source
        let target = min(source.finalSize, reader.dataOffset + prerollBytes)
        while source.availableBytes < target {
            if isCancelled { return }
            setWaiting(true)
            defer { setWaiting(false) }
            switch source.waitForBytes(through: target, timeout: 0.05) {
            case .available, .timedOut: continue
            case .failed(let error): throw error
            case .cancelled: throw CancellationError()
            }
        }
    }

    private func readTracked(into buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        defer { setWaiting(false) }
        return try reader.readLocked(into: buffer)
    }

    private func setWaiting(_ value: Bool) { cond.withLock { waitingForBytes = value } }

    /// Called by the reader's read callback on every poll while it waits for bytes.
    private func readerIsWaiting() {
        cond.lock()
        waitingForBytes = true
        let stall = started && !stalled && outstanding == 0 && !cancelled
        if stall { stalled = true }
        let aborted = cancelled
        cond.unlock()
        if aborted { reader.interrupt() }
        if stall { events(.stalled) }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, last: Bool) throws {
        let expected = node.outputFormat(forBus: 0)
        // A wrong format raises an Objective-C exception inside the node.
        guard buffer.format.sampleRate == expected.sampleRate, buffer.format.channelCount == expected.channelCount,
              buffer.format.commonFormat == expected.commonFormat else { throw ProgressiveError.formatUnsupported }
        cond.lock()
        if cancelled { cond.unlock(); return }
        scheduledFrames += Int64(buffer.frameLength)
        if last {
            scheduledLast = true
        } else {
            outstanding += 1
        }
        cond.unlock()
        if last {
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [finished] _ in finished() }
        } else {
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [self] _ in bufferConsumed() }
        }
        cond.lock()
        let first = !started
        started = true
        let resumed = stalled
        stalled = false
        cond.unlock()
        if first { events(.started) }
        if resumed { events(.resumed) }
    }

    private func bufferConsumed() {
        cond.lock()
        outstanding = max(outstanding - 1, 0)
        cond.broadcast()
        cond.unlock()
    }

    private static func silence(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameCapacity))
        }
    }
}

extension NSCondition {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
