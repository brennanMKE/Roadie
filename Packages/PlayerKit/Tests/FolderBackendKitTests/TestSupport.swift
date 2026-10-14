import AVFoundation
import AudioCore
import CoreGraphics
import Foundation
import ImageIO
import LocalPlayback
import MusicBackendKit
import UniformTypeIdentifiers
import os
@testable import FolderBackendKit

// Every tree is generated under a temp directory and removed by the test. Nothing here opens an audio
// device: the backends get a Player whose resolver points every track at a file that does not exist.

func makeTempDir(_ name: String = "FolderBackendKitTests") -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until `condition` holds (up to `timeout` seconds). No fixed sleeps in the happy path.
@MainActor
func waitFor(timeout: TimeInterval = 10, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A low-amplitude 440 Hz sine, never silence.
func writeWAV(to url: URL, seconds: Double = 0.2, sampleRate: Double = 44_100, channels: Int = 2) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
    ]
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<channels {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            data[i] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
        }
    }
    try file.write(from: buffer)
}

/// An 8-bit RGB image filled with one colour, written as JPEG with ImageIO.
func writeJPEG(to url: URL, size: Int = 64) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func junk(to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not audio".utf8).write(to: url)
}

/// 3 artists, 4 albums, 7 tracks, 2 skipped files (plus ignored sidecars, a hidden folder and empty folders).
func makeLibrary(in root: URL) throws {
    let eden = root.appending(path: "10,000 Maniacs/Our Time in Eden (1992)")
    try writeWAV(to: eden.appending(path: "01 Noah's Dove.wav"))
    try writeWAV(to: eden.appending(path: "02 These Are Days.wav"))
    try writeJPEG(to: eden.appending(path: "cover.jpg"))
    try Data("notes".utf8).write(to: eden.appending(path: "notes.txt"))
    try writeWAV(to: root.appending(path: "10,000 Maniacs/Loose Single.wav"))
    let white = root.appending(path: "The Beatles/The White Album")
    try writeWAV(to: white.appending(path: "Disc 1/01 Back in the U.S.S.R..wav"))
    try writeWAV(to: white.appending(path: "Disc 1/02 Dear Prudence.wav"))
    try writeWAV(to: white.appending(path: "Disc 2/01 Birthday.wav"))
    try writeJPEG(to: white.appending(path: "folder.jpg"))
    try junk(to: root.appending(path: "The Beatles/junk.mp3"))
    try junk(to: root.appending(path: "The Beatles/weird.xyz"))
    try Data("readme".utf8).write(to: root.appending(path: "The Beatles/readme.txt"))
    try writeWAV(to: root.appending(path: "Loose Root.wav"))
    try writeWAV(to: root.appending(path: ".hidden/secret.wav"))
    try FileManager.default.createDirectory(at: root.appending(path: "Empty Artist"), withIntermediateDirectories: true)
    try writeJPEG(to: root.appending(path: "Empty Artist Two/Empty Album/cover.jpg"))
}

func artistID(_ name: String) -> MediaID { MediaID(.artist, name) }
func albumID(_ path: String) -> MediaID { MediaID(.album, path) }
func trackID(_ path: String) -> MediaID { MediaID(.track, path) }

// MARK: Loaders

/// Counts loader calls and where they ran.
actor CountingLoader {
    private(set) var calls: [String] = []
    private(set) var mainThreadCalls = 0
    var count: Int { calls.count }

    func record(_ url: URL, onMain: Bool) {
        calls.append(url.lastPathComponent)
        if onMain { mainThreadCalls += 1 }
    }
}

private func isMainThread() -> Bool { pthread_main_np() != 0 }

/// Holds loader calls while armed. Open it to release them and stop holding.
actor Gate {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }

    func arm() { armed = true }

    func wait() async {
        guard armed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        armed = false
        let released = waiters
        waiters = []
        for waiter in released { waiter.resume() }
    }
}

func countingIndexer(_ counter: CountingLoader, gate: Gate? = nil) -> FolderIndexer {
    FolderIndexer(loader: { url in
        await counter.record(url, onMain: isMainThread())
        if let gate { await gate.wait() }
        return try await LocalTrackLoader.loadTrack(at: url)
    })
}

// MARK: Watchers

final class ManualWatcher: FolderWatching {
    private let state = OSAllocatedUnfairLock(initialState: true)
    let url: URL
    let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    var isRunning: Bool { state.withLock { $0 } }
    func stop() { state.withLock { $0 = false } }
    func fire() { if isRunning { onChange() } }
}

/// Records the watchers a backend creates so a test can fire and inspect them.
final class WatcherRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [ManualWatcher]())
    var watchers: [ManualWatcher] { lock.withLock { $0 } }
    var last: ManualWatcher? { watchers.last }

    var factory: FolderBackend.WatcherFactory {
        { [self] url, onChange in
            let watcher = ManualWatcher(url: url, onChange: onChange)
            lock.withLock { $0.append(watcher) }
            return watcher
        }
    }
}

// MARK: Backends

/// Points every track at a file that does not exist, so the Player goes loading then stopped with an
/// error and never reaches the audio engine.
struct MissingFileResolver: TrackResolver {
    func localURL(for track: Track) async throws -> URL {
        URL(fileURLWithPath: "/nonexistent/\(track.id.uuidString).wav")
    }
}

@MainActor
struct BackendFixture {
    let root: URL
    let resolvedRoot: URL
    let cache: URL
    let player: Player
    let output: LocalPlayerOutput
    let watchers = WatcherRecorder()
    let counter = CountingLoader()
    let gate = Gate()
    let backend: FolderBackend

    init(root: URL, cache: URL? = nil, settings: (@Sendable () -> URL?)? = nil, buildLibrary: Bool = true) throws {
        self.root = root
        self.resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.cache = cache ?? makeTempDir("FolderBackendKitTests-cache")
        if buildLibrary { try makeLibrary(in: root) }
        player = Player(resolver: MissingFileResolver())
        output = LocalPlayerOutput(player: player)
        let provider: @Sendable () -> URL? = settings ?? { root }
        backend = FolderBackend(
            settings: provider, output: output, cacheDirectory: self.cache,
            indexer: countingIndexer(counter, gate: gate), makeWatcher: watchers.factory, rescanDelay: .milliseconds(50))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cache)
    }

    func url(_ relative: String) -> URL { URL(fileURLWithPath: resolvedRoot.path + "/" + relative) }
}

/// Collects a status stream so a test can look for a value without racing it.
@MainActor
final class StatusCollector {
    private(set) var values: [FolderIndexStatus] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<FolderIndexStatus>) {
        task = Task { [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    func stop() { task?.cancel() }
    var sawIndexing: Bool { values.contains { if case .indexing = $0 { true } else { false } } }
    var sawReady: Bool { values.contains { if case .ready = $0 { true } else { false } } }
}
