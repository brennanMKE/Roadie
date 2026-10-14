import Foundation
@testable import SkinKit
import ZIPFoundation

@testable import SkinLibrary

/// A fresh directory under the temp root, removed by `cleanup()`. Every suite makes its own.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "skinlibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    func appending(_ path: String) -> URL { url.appending(path: path) }

    func makeStore() async throws -> SkinIndexStore {
        try await SkinIndexStore.open(at: url.appending(path: "db/index.sqlite"))
    }

    /// A folder for skins inside this directory (so the index database stays outside it).
    func skinsFolder() throws -> URL {
        let folder = url.appending(path: "skins", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

func touch(_ url: URL, mtime: Date = Date()) throws {
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

enum SyntheticSkins {
    /// A 2x2 24-bit BMP (54-byte header, two 8-byte rows), vertically solid in `shade`.
    static func tinyBMP(shade: UInt8 = 0x80) -> Data {
        var data = Data()
        func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        data.append(contentsOf: Array("BM".utf8))
        u32(54 + 16); u32(0); u32(54)
        u32(40); u32(2); u32(2); u16(1); u16(24); u32(0); u32(16); u32(2835); u32(2835); u32(0); u32(0)
        for _ in 0..<2 { data.append(contentsOf: [shade, shade, shade, shade, shade, shade, 0, 0]) }
        return data
    }

    static func zip(_ url: URL, entries: [(name: String, data: Data)]) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.name, type: .file, uncompressedSize: Int64(entry.data.count), compressionMethod: .none
            ) { position, size in
                entry.data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    /// A real `.wsz` that parses through `SkinParser`: every sheet except `omitting`, a viscolor.txt and the readme.
    static func write(
        to url: URL, shade: UInt8 = 0x80, omitting: Set<String> = [], readme: String? = "readme",
        readmeName: String = "readme.txt", extra: [(name: String, data: Data)] = []
    ) throws {
        var entries: [(name: String, data: Data)] = []
        for sheet in SkinSprites.sheets.keys.sorted() where !omitting.contains(sheet) {
            entries.append((sheet.lowercased() + ".bmp", tinyBMP(shade: shade)))
        }
        let colors = (0..<24).map { _ in "10,20,30" }.joined(separator: "\n")
        entries.append(("viscolor.txt", Data(colors.utf8)))
        if let readme { entries.append((readmeName, Data(readme.utf8))) }
        entries.append(contentsOf: extra)
        try zip(url, entries: entries)
    }

    /// A Winamp 3/5 skin: `skin.xml` only.
    static func modern(to url: URL, readme: String? = nil) throws {
        var entries: [(name: String, data: Data)] = [("skin.xml", Data("<WinampAbstractionLayer/>".utf8))]
        if let readme { entries.append(("readme.txt", Data(readme.utf8))) }
        try zip(url, entries: entries)
    }

    static func garbage(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<100).map { UInt8(($0 * 37 + 11) % 251) }).write(to: url)
    }
}

/// An ingester that costs nothing: the hash comes from the path (or an override) and no file is read.
final class StubIngester: SkinIngesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _hashes = 0, _inspections = 0
    private var _mainThreadCalls = 0
    private var overrides: [String: String] = [:]
    let delayPerFile: TimeInterval
    let recordThread: Bool
    let inspection: SkinInspection

    init(
        delayPerFile: TimeInterval = 0, recordThread: Bool = false,
        inspection: SkinInspection = SkinInspection(readme: nil, status: .ok, warnings: [])
    ) {
        self.delayPerFile = delayPerFile
        self.recordThread = recordThread
        self.inspection = inspection
    }

    var hashes: Int { lock.withLock { _hashes } }
    var inspections: Int { lock.withLock { _inspections } }
    var mainThreadCalls: Int { lock.withLock { _mainThreadCalls } }

    /// Makes the file at `path` (relative) hash to `hash`, so two paths can be byte-identical twins.
    func override(path: String, hash: String) { lock.withLock { overrides[path] = hash } }

    private func note(_ url: URL) {
        if delayPerFile > 0 { Thread.sleep(forTimeInterval: delayPerFile) }
        if recordThread && Thread.isMainThread { lock.withLock { _mainThreadCalls += 1 } }
    }

    func hash(_ url: URL) throws -> String {
        lock.withLock { _hashes += 1 }
        note(url)
        // The stub keys by the file's path below the skins folder: the last two components are unique in tests.
        let key = relative(url)
        return lock.withLock { overrides[key] } ?? "stub:" + key
    }

    func inspect(_ url: URL) -> SkinInspection {
        lock.withLock { _inspections += 1 }
        note(url)
        return inspection
    }

    private func relative(_ url: URL) -> String {
        let parts = url.pathComponents
        return parts.suffix(2).joined(separator: "/")
    }
}

/// Wraps the real ingester and counts calls.
final class CountingIngester: SkinIngesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _hashes = 0, _inspections = 0
    private let base = SkinIngester()
    var hashes: Int { lock.withLock { _hashes } }
    var inspections: Int { lock.withLock { _inspections } }

    func hash(_ url: URL) throws -> String {
        lock.withLock { _hashes += 1 }
        return try base.hash(url)
    }

    func inspect(_ url: URL) -> SkinInspection {
        lock.withLock { _inspections += 1 }
        return base.inspect(url)
    }
}

/// A lock-protected box for values the progress callback records.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func add(_ value: T) { lock.withLock { values.append(value) } }
    var all: [T] { lock.withLock { values } }
}
