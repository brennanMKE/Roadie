import CoreServices
import Foundation
import os

public protocol FolderWatching: AnyObject, Sendable {
    var isRunning: Bool { get }
    func stop()
}

/// FSEvents on one root, recursive. Fires `onChange` on a private queue, at most once per `latency`.
/// Any event means "rescan": the paths are ignored.
public final class FSEventsFolderWatcher: FolderWatching, @unchecked Sendable {
    /// What the C callback reaches. Retained by the stream's context, so a late callback never sees freed memory.
    private final class Box: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock(initialState: true)
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func fire() {
            if lock.withLock({ $0 }) { onChange() }
        }
    }

    private let box: Box
    private let queue = DispatchQueue(label: "co.sstools.roadie.FolderWatcher")
    private struct Handle: @unchecked Sendable { var stream: FSEventStreamRef }
    private let state = OSAllocatedUnfairLock<Handle?>(initialState: nil)

    public var isRunning: Bool { state.withLock { $0 != nil } }

    public init(url: URL, latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        box = Box(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().fire()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        // Not IgnoreSelf: the app never writes into the music folder, and that flag would hide the
        // test's own writes (events caused by the calling process are dropped).
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags) else {
            // The context was not retained by a stream that was never made.
            Unmanaged.passUnretained(box).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            let handle = Handle(stream: stream)
            state.withLock { $0 = handle }
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public static func make(url: URL, onChange: @escaping @Sendable () -> Void) -> any FolderWatching {
        FSEventsFolderWatcher(url: url, onChange: onChange)
    }

    /// Idempotent.
    public func stop() {
        box.lock.withLock { $0 = false }
        guard let handle = state.withLock({ current -> Handle? in
            defer { current = nil }
            return current
        }) else { return }
        let stream = handle.stream
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
