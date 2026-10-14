import Foundation

public enum ProgressiveWaitOutcome: Sendable {
    /// The bytes asked for are on disk.
    case available
    /// The timeout passed first; call again. The reader polls so it can notice an interrupt.
    case timedOut
    case failed(any Error)
    case cancelled
}

/// One file whose bytes arrive in order. Implemented by TrackCache over its temp file.
/// `waitForBytes`, `read` and `fetchRange` block the calling thread and are only ever called from a
/// reader or feeder `Thread`, never from a Swift concurrency task.
public protocol ProgressiveByteSource: AnyObject, Sendable {
    /// The size of the complete file.
    var finalSize: Int64 { get }
    /// Contiguous bytes from offset 0 that are on disk now.
    var availableBytes: Int64 { get }
    /// "m4a", "mp3", ... (the cache's sanitized extension); AudioCore maps it to an `AudioFileTypeID` hint.
    var pathExtension: String { get }
    /// Returns when `availableBytes >= end`, the download fails, `cancel()` is called, or `timeout` seconds pass.
    func waitForBytes(through end: Int64, timeout: TimeInterval) -> ProgressiveWaitOutcome
    /// `pread` on the temp file. Short only at `finalSize`.
    func read(into buffer: UnsafeMutableRawPointer, offset: Int64, count: Int) throws -> Int
    /// Out-of-order bytes by range request; never written to the file.
    func fetchRange(_ range: Range<Int64>) throws -> Data
    /// Wakes a blocked `waitForBytes` / `fetchRange` with `.cancelled`.
    func cancel()
    /// The reader is done; the source may cancel the download if nobody else needs it. Idempotent.
    func close()
}
