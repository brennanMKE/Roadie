import CoreGraphics
import Foundation
@testable import SkinKit
@testable import SkinLibrary

enum TestBMP {
    /// A 24-bit BMP of one colour: 54-byte header, bottom-up rows padded to 4 bytes.
    static func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> Data {
        let rowSize = (width * 3 + 3) / 4 * 4
        var data = Data()
        func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        data.append(contentsOf: Array("BM".utf8))
        u32(54 + rowSize * height); u32(0); u32(54)
        u32(40); u32(width); u32(height); u16(1); u16(24); u32(0); u32(rowSize * height); u32(2835); u32(2835); u32(0); u32(0)
        var row = [UInt8]()
        for _ in 0..<width { row.append(contentsOf: [b, g, r]) }
        row.append(contentsOf: [UInt8](repeating: 0, count: rowSize - width * 3))
        for _ in 0..<height { data.append(contentsOf: row) }
        return data
    }
}

extension SyntheticSkins {
    /// A real skin whose main.bmp is 275x116 of one colour, so a thumbnail pixel can be checked.
    static func write(to url: URL, mainColor: (r: UInt8, g: UInt8, b: UInt8)) throws {
        try write(
            to: url, omitting: ["MAIN"],
            extra: [("main.bmp", TestBMP.solid(width: 275, height: 116, r: mainColor.r, g: mainColor.g, b: mainColor.b))])
    }

    /// A skin with only main.bmp (the renderer's partial-skin rule still draws it).
    static func writeMainOnly(to url: URL) throws {
        try write(
            to: url, omitting: Set(SkinSprites.sheets.keys).subtracting(["MAIN"]),
            extra: [("main.bmp", TestBMP.solid(width: 275, height: 116, r: 1, g: 2, b: 3))])
    }
}

/// RGBA of the pixel at (x, y), y from the top, through a device-RGB context.
func rgba(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let offset = (y * image.width + x) * 4
    return Array(pixels[offset..<offset + 4])
}

func solidImage(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    let context = CGContext(
        data: nil, width: 275, height: 116, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 275, height: 116))
    return context.makeImage()!
}

/// Suspends callers of `wait()` until `open()`, without holding a thread (#0094). `open()` is idempotent.
final class AsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for continuation in toResume { continuation.resume() }
    }
}

/// An injectable renderer that records what happens to it. With a `latch`, every render waits for it.
final class CountingRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    private var _current = 0, _max = 0, _finished = 0
    private var _sawMain = false
    let latch: AsyncLatch?
    let color: (UInt8, UInt8, UInt8)

    init(latch: AsyncLatch? = nil, color: (UInt8, UInt8, UInt8) = (200, 40, 40)) {
        self.latch = latch
        self.color = color
    }

    var started: [String] { lock.withLock { _started } }
    var finished: Int { lock.withLock { _finished } }
    var maxSimultaneous: Int { lock.withLock { _max } }
    var sawMainThread: Bool { lock.withLock { _sawMain } }

    var closure: @Sendable (URL) async throws(SkinError) -> CGImage {
        { (url: URL) async throws(SkinError) -> CGImage in await self.render(url) }
    }

    private func render(_ url: URL) async -> CGImage {
        lock.withLock {
            _started.append(url.lastPathComponent)
            _current += 1
            _max = max(_max, _current)
            if Thread.isMainThread { _sawMain = true }
        }
        await latch?.wait()
        lock.withLock {
            _current -= 1
            _finished += 1
        }
        return solidImage(r: color.0, g: color.1, b: color.2)
    }
}

/// Polls (yielding the thread, no timing assertion) until `condition` holds.
func waitUntil(_ condition: @Sendable () async -> Bool) async {
    while !(await condition()) { try? await Task.sleep(for: .milliseconds(1)) }
}

/// A valid hash and an existing placeholder file for a fake skin called `name`.
func fakeSkin(in dir: TempDir, _ name: String) throws -> (hash: String, url: URL) {
    let url = dir.appending("skins/\(name).wsz")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(name.utf8).write(to: url)
    return (SkinContentHash.hex(of: Data(name.utf8)), url)
}
