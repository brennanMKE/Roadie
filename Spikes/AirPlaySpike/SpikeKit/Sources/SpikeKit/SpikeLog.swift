import Foundation
import os

/// Timestamped lines to a file and to os_log. Each line: `HH:mm:ss.SSS <engine> <message>`.
public final class SpikeLog: @unchecked Sendable {
    public static let subsystem = "com.brennanmke.AirPlaySpike"

    private let logger = Logger(subsystem: SpikeLog.subsystem, category: "Spike")
    private let lock = NSLock()
    private var handle: FileHandle?
    private var markCount = 0
    public let directory: URL
    public let fileURL: URL

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AirPlaySpike", isDirectory: true)
    }

    public init(directory: URL = SpikeLog.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = directory.appendingPathComponent("spike-\(f.string(from: Date())).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    deinit { try? handle?.close() }

    public func log(_ engine: String, _ message: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(engine) \(message)"
        logger.notice("\(line, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        if let data = (line + "\n").data(using: .utf8) { try? handle?.write(contentsOf: data) }
    }

    /// A user-timed event ("press Mark when you hear it"). Returns the mark number.
    @discardableResult
    public func mark(engine: String) -> Int {
        lock.lock()
        markCount += 1
        let n = markCount
        lock.unlock()
        log(engine, "MARK \(n)")
        return n
    }
}
