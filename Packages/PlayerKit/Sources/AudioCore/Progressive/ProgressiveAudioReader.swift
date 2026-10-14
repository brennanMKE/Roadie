import AVFoundation
import AudioToolbox
import Foundation
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "Progressive")

enum ProgressiveError: Error, LocalizedError, Equatable {
    /// The container cannot be read while it is still downloading (a far jump past the side-fetch
    /// budget, an unknown length). The player falls back to the whole-file path.
    case notStreamable(String)
    case open(OSStatus)
    case read(OSStatus)
    /// ExtAudioFile cannot convert the file to the graph's format. Also a fallback trigger.
    case formatUnsupported

    var isFallbackTrigger: Bool {
        switch self {
        case .notStreamable, .formatUnsupported: true
        case .open, .read: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notStreamable: "This file cannot be played while it downloads."
        case .open: "This file is not a supported audio file."
        case .read: "This audio file could not be read."
        case .formatUnsupported: "This audio file's format is not supported."
        }
    }
}

/// An `ExtAudioFile` over a file that is still arriving. CoreAudio opens an `AudioFileID` through
/// `AudioFileOpenWithCallbacks`; the read callback serves bytes from the `ProgressiveByteSource`, blocks
/// (always on a plain `Thread`, never a cooperative task) while the sequential download catches up, and
/// turns a far jump into a range request. The decoders are the ones `AVAudioFile` wraps, so the decoded
/// frames are the same as the whole-file path.
///
/// Every AudioToolbox call happens with `io` held, from one thread at a time: either a short-lived
/// thread (`open`, `setClientFormat`) or a feeder's thread, which holds the lock for its whole session.
final class ProgressiveAudioReader: @unchecked Sendable {
    private struct State {
        var lastError: (any Error)?
        var sideFetched: Int64 = 0
        var sideCache: [(range: Range<Int64>, data: Data)] = []
        /// Aborts the read in progress (a feeder was cancelled); cleared by the next session.
        var interrupted = false
        var closed = false
        var onWaiting: (@Sendable () -> Void)?
    }

    let source: any ProgressiveByteSource
    let policy: ProgressiveReadPolicy
    private let io = NSLock()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var fileID: AudioFileID?
    private var ext: ExtAudioFileRef?

    /// Set during `open`, immutable afterwards.
    private(set) var lengthFrames: Int64 = 0
    private(set) var fileSampleRate: Double = 0
    private(set) var fileChannels: Int = 0
    private(set) var dataOffset: Int64 = 0

    private var clientDescription: AudioStreamBasicDescription?
    /// ExtAudioFileSeek's unit differs from the file's when the client rate differs; learned once.
    private var positionIsClientRate = false
    private var positionCalibrated = false

    private init(source: any ProgressiveByteSource, policy: ProgressiveReadPolicy) {
        self.source = source
        self.policy = policy
    }

    var sideFetchedBytes: Int64 { state.withLock { $0.sideFetched } }
    var isOpen: Bool { state.withLock { !$0.closed } && ext != nil }

    // MARK: Open

    /// Parses the container header while the download continues. No client format and no audio graph
    /// yet: a corrupt or non-audio file fails here, before the player ever touches the output device.
    /// Cancelling the task cancels the source, which wakes a read blocked on bytes that never arrive.
    static func open(
        _ source: any ProgressiveByteSource, policy: ProgressiveReadPolicy = .init()
    ) async throws -> ProgressiveAudioReader {
        let reader = ProgressiveAudioReader(source: source, policy: policy)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let thread = Thread {
                    reader.io.lock()
                    defer { reader.io.unlock() }
                    do {
                        try reader.openFileLocked()
                        continuation.resume()
                    } catch {
                        reader.disposeLocked()
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "SkinAmp.progressive-open"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            source.cancel()
        }
        log.debug("opened: \(source.pathExtension, privacy: .public) \(reader.lengthFrames) frames, side-fetched \(reader.sideFetchedBytes) bytes")
        return reader
    }

    private func openFileLocked() throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var fid: AudioFileID?
        var status = AudioFileOpenWithCallbacks(
            refcon, Self.readProc, nil, Self.sizeProc, nil, Self.typeHint(for: source.pathExtension), &fid)
        guard status == noErr, let fid else { throw failure(status) { .open($0) } }
        fileID = fid
        var wrapped: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fid, false, &wrapped)
        guard status == noErr, let wrapped else { throw failure(status) { .open($0) } }
        ext = wrapped

        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileDataFormat, &size, &description)
        guard status == noErr else { throw failure(status) { .open($0) } }
        var length: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        status = ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileLengthFrames, &size, &length)
        guard status == noErr else { throw failure(status) { .open($0) } }
        guard length > 0, description.mSampleRate > 0 else { throw ProgressiveError.notStreamable("unknown length") }
        var offset: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertyDataOffset, &size, &offset) != noErr { offset = 0 }

        lengthFrames = length
        fileSampleRate = description.mSampleRate
        fileChannels = Int(description.mChannelsPerFrame)
        dataOffset = max(offset, 0)
    }

    private static func typeHint(for pathExtension: String) -> AudioFileTypeID {
        switch pathExtension.lowercased() {
        case "mp3": kAudioFileMP3Type
        case "m4a", "m4b", "mp4", "m4p": kAudioFileM4AType
        case "aac": kAudioFileAAC_ADTSType
        case "wav", "wave": kAudioFileWAVEType
        case "aif", "aiff": kAudioFileAIFFType
        case "caf": kAudioFileCAFType
        case "flac": kAudioFileFLACType
        default: 0
        }
    }

    // MARK: Client format

    /// The format ExtAudioFile decodes to (the graph's: float, the node's rate, 2 channels). Runs on a
    /// short-lived thread: setting it can touch the file. Refusal is `.formatUnsupported`.
    func setClientFormat(_ description: AudioStreamBasicDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let thread = Thread {
                self.io.lock()
                defer { self.io.unlock() }
                do {
                    try self.applyClientFormatLocked(description)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "SkinAmp.progressive-format"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Caller holds the lock. A no-op when the format is already set.
    func applyClientFormatLocked(_ description: AudioStreamBasicDescription) throws {
        if let current = clientDescription, Self.same(current, description) { return }
        guard let ext else { throw ProgressiveError.formatUnsupported }
        var copy = description
        let status = ExtAudioFileSetProperty(
            ext, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &copy)
        guard status == noErr else {
            if let error = takeLastError() { throw error }
            throw ProgressiveError.formatUnsupported
        }
        clientDescription = copy
        positionCalibrated = false
        positionIsClientRate = false
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mFormatFlags == b.mFormatFlags && a.mBitsPerChannel == b.mBitsPerChannel
    }

    // MARK: Reading (caller holds the lock, normally through `session`)

    /// Runs `body` with exclusive use of the file. A feeder holds this for its whole session, so a
    /// restarted feeder starts only after the previous one has let go.
    func session<T>(_ body: () throws -> T) rethrows -> T {
        io.lock()
        defer { io.unlock() }
        return try body()
    }

    /// Lets the next session read after a previous one was interrupted.
    func beginSessionLocked() {
        state.withLock {
            $0.interrupted = false
            $0.lastError = nil
        }
    }

    /// Aborts the read in progress, if any, within one poll interval.
    func interrupt() { state.withLock { $0.interrupted = true } }

    func setWaitingHandler(_ handler: (@Sendable () -> Void)?) { state.withLock { $0.onWaiting = handler } }

    /// Decodes up to the buffer's capacity. Returns the frames decoded; 0 is the end of the file.
    func readLocked(into buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        guard let ext else { throw ProgressiveError.read(kAudioFileNotOpenError) }
        buffer.frameLength = buffer.frameCapacity
        var frames = buffer.frameCapacity
        let status = ExtAudioFileRead(ext, &frames, buffer.mutableAudioBufferList)
        guard status == noErr else { throw failure(status) { .read($0) } }
        buffer.frameLength = frames
        return frames
    }

    /// `frame` is in the file's sample rate.
    func seekLocked(toFrame frame: Int64) throws {
        guard let ext else { throw ProgressiveError.read(kAudioFileNotOpenError) }
        var target = frame
        if positionIsClientRate, let client = clientDescription, fileSampleRate > 0 {
            target = Int64((Double(frame) * client.mSampleRate / fileSampleRate).rounded())
        }
        let status = ExtAudioFileSeek(ext, target)
        guard status == noErr else { throw failure(status) { .read($0) } }
    }

    /// Learns whether `ExtAudioFileSeek` counts frames at the file's rate or the client's, by decoding a
    /// few frames from the start and asking `Tell`. Only matters when the two rates differ (a 44.1 kHz
    /// file on a 48 kHz device). Leaves the position at the start.
    func calibratePositionUnitsLocked() throws {
        guard !positionCalibrated else { return }
        positionCalibrated = true
        guard var client = clientDescription, abs(client.mSampleRate - fileSampleRate) > 0.5, let ext,
              let format = AVAudioFormat(streamDescription: &client),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return }
        try seekLocked(toFrame: 0)
        let read = try readLocked(into: scratch)
        var tell: Int64 = 0
        guard read > 0, ExtAudioFileTell(ext, &tell) == noErr else { return }
        let asClient = abs(tell - Int64(read))
        let asFile = abs(tell - Int64((Double(read) * fileSampleRate / client.mSampleRate).rounded()))
        positionIsClientRate = asClient < asFile
        log.debug("seek units are \(self.positionIsClientRate ? "client" : "file", privacy: .public) rate")
        try seekLocked(toFrame: 0)
    }

    // MARK: Convenience for tests and one-off use

    func read(into buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        try session {
            beginSessionLocked()
            return try readLocked(into: buffer)
        }
    }

    func seek(toFrame frame: Int64) throws {
        try session { try seekLocked(toFrame: frame) }
    }

    // MARK: Buffered extent

    /// File frames that can be decoded without waiting: all of them once the download is complete, else
    /// the byte-proportional share minus the preroll's worth. Exact for CBR; for VBR the reader still
    /// waits for the real bytes, so a slightly optimistic value shows "buffering" instead of a wrong frame.
    func bufferedFrames() -> Int64 {
        let available = source.availableBytes
        let total = source.finalSize
        if available >= total { return lengthFrames }
        let span = max(total - dataOffset, 1)
        let share = Double(max(available - dataOffset, 0)) / Double(span)
        let preroll = Int64(policy.prerollSeconds * fileSampleRate)
        return min(max(Int64(Double(lengthFrames) * share) - preroll, 0), lengthFrames)
    }

    // MARK: Teardown

    /// Wakes anything blocked and cancels the source.
    func cancel() {
        state.withLock { $0.interrupted = true }
        source.cancel()
    }

    /// Disposes the file on a background thread (a blocked read lets go within one poll) and then closes
    /// the source. Idempotent. Never blocks the caller.
    func close() {
        let first = state.withLock { state -> Bool in
            defer { state.closed = true; state.interrupted = true }
            return !state.closed
        }
        guard first else { return }
        let thread = Thread {
            self.io.lock()
            self.disposeLocked()
            self.io.unlock()
            self.source.close()
        }
        thread.name = "SkinAmp.progressive-close"
        thread.start()
    }

    private func disposeLocked() {
        if let ext { ExtAudioFileDispose(ext) }
        if let fileID { AudioFileClose(fileID) }
        ext = nil
        fileID = nil
    }

    // MARK: Errors

    private func stash(_ error: any Error) {
        state.withLock { if $0.lastError == nil { $0.lastError = error } }
    }

    private func takeLastError() -> (any Error)? {
        state.withLock { state in
            defer { state.lastError = nil }
            return state.lastError
        }
    }

    /// The Swift error the read callback stashed (a failed download, a cancel) wins over CoreAudio's status.
    private func failure(_ status: OSStatus, _ make: (OSStatus) -> ProgressiveError) -> any Error {
        takeLastError() ?? make(status)
    }

    // MARK: AudioFile callbacks

    private static let readProc: AudioFile_ReadProc = { refcon, position, requestCount, buffer, actualCount in
        Unmanaged<ProgressiveAudioReader>.fromOpaque(refcon).takeUnretainedValue()
            .serve(position: position, count: requestCount, into: buffer, actual: actualCount)
    }

    private static let sizeProc: AudioFile_GetSizeProc = { refcon in
        Unmanaged<ProgressiveAudioReader>.fromOpaque(refcon).takeUnretainedValue().source.finalSize
    }

    private static let pollSeconds: TimeInterval = 0.05

    private func serve(
        position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer, actual: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        actual.pointee = 0
        let finalSize = source.finalSize
        while true {
            let (interrupted, sideFetched) = state.withLock { ($0.interrupted || $0.closed, $0.sideFetched) }
            if interrupted {
                stash(CancellationError())
                return kAudioFileUnspecifiedError
            }
            switch policy.decide(
                offset: position, count: Int(count), available: source.availableBytes, finalSize: finalSize,
                sideFetched: sideFetched) {
            case .endOfFile:
                return noErr
            case .serve:
                let wanted = Int(min(Int64(count), finalSize - position))
                do {
                    actual.pointee = UInt32(try source.read(into: buffer, offset: position, count: wanted))
                    return noErr
                } catch {
                    stash(error)
                    return kAudioFileUnspecifiedError
                }
            case .wait(let through):
                state.withLock { $0.onWaiting }?()
                switch source.waitForBytes(through: through, timeout: Self.pollSeconds) {
                case .available, .timedOut:
                    continue
                case .failed(let error):
                    stash(error)
                    return kAudioFileUnspecifiedError
                case .cancelled:
                    stash(CancellationError())
                    return kAudioFileUnspecifiedError
                }
            case .sideFetch(let range):
                do {
                    let data = try sideFetch(range, finalSize: finalSize)
                    data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
                    actual.pointee = UInt32(data.count)
                    return noErr
                } catch {
                    stash(error)
                    return kAudioFileUnspecifiedError
                }
            case .giveUp:
                stash(ProgressiveError.notStreamable("range budget spent"))
                return kAudioFileUnspecifiedError
            }
        }
    }

    /// Bytes for `range` from the in-memory range cache or one rounded-out range request.
    private func sideFetch(_ range: Range<Int64>, finalSize: Int64) throws -> Data {
        if let hit = state.withLock({ state in state.sideCache.first { $0.range.contains(range.lowerBound) && $0.range.upperBound >= range.upperBound } }) {
            return Self.slice(hit.data, of: hit.range, range)
        }
        let granule = max(policy.sideFetchGranularity, 1)
        let low = range.lowerBound / granule * granule
        let high = min((range.upperBound + granule - 1) / granule * granule, finalSize)
        let wanted = low..<high
        let data = try source.fetchRange(wanted)
        guard Int64(data.count) == wanted.count else { throw ProgressiveError.read(kAudioFileEndOfFileError) }
        state.withLock {
            $0.sideFetched += Int64(data.count)
            $0.sideCache.append((wanted, data))
        }
        return Self.slice(data, of: wanted, range)
    }

    private static func slice(_ data: Data, of outer: Range<Int64>, _ inner: Range<Int64>) -> Data {
        let start = Int(inner.lowerBound - outer.lowerBound)
        return data.subdata(in: data.startIndex.advanced(by: start)..<data.startIndex.advanced(by: start + Int(inner.count)))
    }
}
