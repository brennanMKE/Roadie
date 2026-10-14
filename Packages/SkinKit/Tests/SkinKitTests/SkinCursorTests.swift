import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkinKit

// MARK: Fixture builders (everything is synthetic; no third-party cursor files)

private struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v); u8(v >> 8) }
    mutating func u32(_ v: Int) { u16(v); u16(v >> 16) }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func ascii(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
}

/// One ICO/CUR directory entry and its DIB.
private struct CurSpec {
    var width: Int
    var height: Int
    var bitCount: Int = 24
    /// BGR triples, written as BGRx quads.
    var palette: [[UInt8]] = []
    /// Top-down packed rows (unpadded); the builder pads them and stores them bottom-up.
    var xorRows: [[UInt8]]
    /// Top-down; nil = an all-opaque (AND 0) mask.
    var andRows: [[Bool]]?
    var hasMask = true
    var hotSpot = (x: 0, y: 0)
    var clrUsed: Int?
    var biSize = 40
    var compression = 0
    var widthField: Int?
    var heightField: Int?
    var bitCountField: Int?

    func dib() -> [UInt8] {
        var w = ByteWriter()
        w.u32(biSize); w.u32(widthField ?? width); w.u32(heightField ?? (hasMask ? height * 2 : height)); w.u16(1)
        w.u16(bitCountField ?? bitCount); w.u32(compression); w.u32(0); w.u32(0); w.u32(0)
        w.u32(clrUsed ?? (bitCount <= 8 ? palette.count : 0)); w.u32(0)
        while w.bytes.count < biSize { w.u8(0) }
        for color in palette { w.append(color); w.u8(0) }
        let xorStride = (width * bitCount + 31) / 32 * 4
        for row in xorRows.reversed() {
            w.append(row)
            w.append([UInt8](repeating: 0, count: max(xorStride - row.count, 0)))
        }
        if hasMask {
            let andStride = (width + 31) / 32 * 4
            for y in (0..<height).reversed() {
                var row = [UInt8](repeating: 0, count: andStride)
                if let andRows { for x in 0..<width where andRows[y][x] { row[x / 8] |= 0x80 >> UInt8(x % 8) } }
                w.append(row)
            }
        }
        return w.bytes
    }
}

private func makeCurFile(_ specs: [CurSpec], type: Int = 2) -> [UInt8] {
    var w = ByteWriter()
    w.u16(0); w.u16(type); w.u16(specs.count)
    var offset = 6 + 16 * specs.count
    let dibs = specs.map { $0.dib() }
    for (spec, dib) in zip(specs, dibs) {
        w.u8(spec.width >= 256 ? 0 : spec.width); w.u8(spec.height >= 256 ? 0 : spec.height); w.u8(0); w.u8(0)
        w.u16(spec.hotSpot.x); w.u16(spec.hotSpot.y); w.u32(dib.count); w.u32(offset)
        offset += dib.count
    }
    for dib in dibs { w.append(dib) }
    return w.bytes
}

private func makeCur(_ spec: CurSpec, type: Int = 2) -> [UInt8] { makeCurFile([spec], type: type) }

private func solid24(width: Int, height: Int, bgr: [UInt8], hotSpot: (x: Int, y: Int) = (0, 0)) -> CurSpec {
    CurSpec(
        width: width, height: height, xorRows: Array(repeating: Array((0..<width).map { _ in bgr }.joined()), count: height),
        hotSpot: hotSpot)
}

/// The fixture for test 1: 4x4, 4-bit, palette [black, red, white, blue], pixel (0,0) red, hotspot (1,2).
private func fixtureOne() -> [UInt8] {
    var rows = Array(repeating: [UInt8](repeating: 0, count: 2), count: 4)
    rows[0] = [0x10, 0x00]
    return makeCur(
        CurSpec(
            width: 4, height: 4, bitCount: 4, palette: [[0, 0, 0], [0, 0, 255], [255, 255, 255], [255, 0, 0]], xorRows: rows,
            hotSpot: (1, 2)))
}

private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
    var w = ByteWriter()
    w.ascii(id); w.u32(body.count); w.append(body)
    if body.count % 2 == 1 { w.u8(0) }
    return w.bytes
}

private func list(_ form: String, _ children: [UInt8]) -> [UInt8] { chunk("LIST", Array(form.utf8) + children) }

private struct AniSpec {
    var frames: [[UInt8]]
    var rate: [Int]?
    var seq: [Int]?
    var dispRate = 10
    var flags = 1
    var nSteps: Int?
    var nestFramInInfo = false
    var includeAnih = true
    var form = "ACON"
    var anihWidth = 32
    var anihBits = 24
    var trailing: [UInt8] = []
    var riffSizeOverride: Int?

    func build() -> [UInt8] {
        var body = Array(form.utf8)
        if includeAnih {
            var a = ByteWriter()
            a.u32(36); a.u32(frames.count); a.u32(nSteps ?? frames.count); a.u32(anihWidth); a.u32(anihWidth)
            a.u32(anihBits); a.u32(1); a.u32(dispRate); a.u32(flags)
            body += chunk("anih", a.bytes)
        }
        if let rate { var r = ByteWriter(); rate.forEach { r.u32($0) }; body += chunk("rate", r.bytes) }
        if let seq { var s = ByteWriter(); seq.forEach { s.u32($0) }; body += chunk("seq ", s.bytes) }
        if !frames.isEmpty {
            let fram = list("fram", frames.flatMap { chunk("icon", $0) })
            body += nestFramInInfo ? list("INFO", chunk("INAM", Array("abc".utf8)) + fram) : fram
        }
        body += trailing
        var w = ByteWriter()
        w.ascii("RIFF"); w.u32(riffSizeOverride ?? body.count); w.append(body)
        return w.bytes
    }
}

private func cur24(_ r: UInt8, _ g: UInt8, _ b: UInt8, size: Int = 4) -> [UInt8] {
    makeCur(solid24(width: size, height: size, bgr: [b, g, r]))
}

private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setBlendMode(.copy)
        context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }
    return bytes.map(Int.init)
}

private func parse(_ bytes: [UInt8]) -> SkinCursor? { CursorParser.parse(Data(bytes)) }

private func makePNG(width: Int, height: Int) -> [UInt8] {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return [UInt8](data as Data)
}

/// Deterministic pseudo-random numbers for the mutation runs.
private struct LCG {
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    mutating func next() -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state >> 33)
    }
}

// MARK: Tests

@Suite struct SkinCursorTests {
    @Test func curHeaderIsParsedWithHotSpot() throws {
        let cursor = try #require(parse(fixtureOne()))
        #expect(cursor.frames.count == 1)
        #expect(cursor.frames[0].image.width == 4 && cursor.frames[0].image.height == 4)
        #expect(cursor.frames[0].hotSpot == CGPoint(x: 1, y: 2))
        #expect(cursor.steps == [SkinCursor.Step(frame: 0, duration: 0)])
        #expect(!cursor.isAnimated)
        #expect(cursor.cycleDuration == 0)
        #expect(rgba(cursor.frames[0].image, 0, 0) == [255, 0, 0, 255])
        #expect(rgba(cursor.frames[0].image, 1, 0) == [0, 0, 0, 255])
    }

    @Test func andMaskMakesPixelsTransparentOrInverted() throws {
        var spec = CurSpec(
            width: 8, height: 1, bitCount: 1, palette: [[0, 0, 0], [255, 255, 255]], xorRows: [[0b0100_0000]],
            andRows: [[true, true, false, false, false, false, false, false]])
        let masked = try #require(parse(makeCur(spec))).frames[0].image
        #expect(rgba(masked, 0, 0)[3] == 0)                       // AND 1 over black: transparent
        #expect(rgba(masked, 1, 0) == [255, 255, 255, 255])       // AND 1 over white: inverted, drawn opaque white
        #expect(rgba(masked, 2, 0) == [0, 0, 0, 255])             // AND 0 over black: opaque black
        spec.hasMask = false
        let plain = try #require(parse(makeCur(spec))).frames[0].image
        #expect(rgba(plain, 0, 0) == [0, 0, 0, 255])
        #expect(rgba(plain, 5, 0) == [0, 0, 0, 255])
    }

    @Test func paletteIndexAndRowOrderAreHonoured() throws {
        // 5x3, 8-bit (stride 8 with padding), three palette entries, one colour per row. Row 1 holds an index past
        // the palette at x 4.
        let spec = CurSpec(
            width: 5, height: 3, bitCount: 8, palette: [[0, 0, 255], [0, 255, 0], [255, 0, 0]],
            xorRows: [[0, 0, 0, 0, 0], [1, 1, 1, 1, 5], [2, 2, 2, 2, 2]], clrUsed: 3)
        let image = try #require(parse(makeCur(spec))).frames[0].image
        #expect(rgba(image, 0, 0) == [255, 0, 0, 255])
        #expect(rgba(image, 4, 0) == [255, 0, 0, 255])
        #expect(rgba(image, 0, 1) == [0, 255, 0, 255])
        #expect(rgba(image, 4, 1) == [0, 0, 0, 255])
        #expect(rgba(image, 4, 2) == [0, 0, 255, 255])
    }

    @Test func trueColourAndAlphaDecode() throws {
        let rgb24 = try #require(parse(makeCur(CurSpec(width: 2, height: 1, xorRows: [[30, 20, 10, 60, 50, 40]])))).frames[0].image
        #expect(rgba(rgb24, 0, 0) == [10, 20, 30, 255])
        #expect(rgba(rgb24, 1, 0) == [40, 50, 60, 255])

        let noAlpha = try #require(
            parse(makeCur(CurSpec(width: 1, height: 1, bitCount: 32, xorRows: [[1, 2, 3, 0]])))).frames[0].image
        #expect(rgba(noAlpha, 0, 0) == [3, 2, 1, 255])

        // One pixel at alpha 128 (premultiplied on read-back); AND 1 still clears the other.
        let alpha = CurSpec(
            width: 2, height: 1, bitCount: 32, xorRows: [[0, 0, 200, 128, 0, 0, 200, 255]], andRows: [[false, true]])
        let image = try #require(parse(makeCur(alpha))).frames[0].image
        let p = rgba(image, 0, 0)
        #expect(p[3] == 128)
        #expect(abs(p[0] - 100) <= 2)
        #expect(rgba(image, 1, 0)[3] == 0)

        let red555 = try #require(parse(makeCur(CurSpec(width: 1, height: 1, bitCount: 16, xorRows: [[0x00, 0x7C]])))).frames[0].image
        let q = rgba(red555, 0, 0)
        #expect(abs(q[0] - 255) <= 8 && q[1] <= 8 && q[2] <= 8 && q[3] == 255)
    }

    @Test func pngEntryDecodesThroughImageIO() throws {
        let png = makePNG(width: 2, height: 2)
        var w = ByteWriter()
        w.u16(0); w.u16(2); w.u16(1)
        w.u8(2); w.u8(2); w.u8(0); w.u8(0); w.u16(1); w.u16(1); w.u32(png.count); w.u32(22)
        w.append(png)
        let cursor = try #require(parse(w.bytes))
        #expect(cursor.frames[0].image.width == 2 && cursor.frames[0].image.height == 2)
        #expect(cursor.frames[0].hotSpot == CGPoint(x: 1, y: 1))
    }

    @Test func bestEntryIsClosestToThirtyTwo() throws {
        func spec(_ size: Int, bits: Int, index: UInt8) -> CurSpec {
            let rowBytes = (size * bits + 7) / 8
            let packed: [UInt8] = bits == 1 ? [UInt8](repeating: 0, count: rowBytes)
                : bits == 4 ? [UInt8](repeating: index << 4 | index, count: rowBytes)
                : [UInt8](repeating: index, count: rowBytes)
            return CurSpec(
                width: size, height: size, bitCount: bits,
                palette: Array([[0, 0, 0], [0, 0, 255], [255, 0, 0]].prefix(bits == 1 ? 2 : 3)),
                xorRows: Array(repeating: packed, count: size))
        }
        let three = makeCurFile([spec(16, bits: 1, index: 0), spec(32, bits: 4, index: 1), spec(48, bits: 8, index: 2)])
        #expect(parse(three)?.frames[0].image.width == 32)

        // Two 32x32 entries: the higher bit depth wins (blue is the 8-bit one).
        let two = makeCurFile([spec(32, bits: 4, index: 1), spec(32, bits: 8, index: 2)])
        let image = try #require(parse(two)).frames[0].image
        #expect(rgba(image, 0, 0) == [0, 0, 255, 255])

        // ICO (type 1): the hotspot fields are planes/bit count, so the hotspot is (0, 0).
        var ico = spec(4, bits: 8, index: 1)
        ico.hotSpot = (1, 8)
        #expect(parse(makeCur(ico, type: 1))?.frames[0].hotSpot == .zero)
    }

    @Test func malformedCursorsReturnNil() throws {
        let base = fixtureOne()
        func patched(_ edit: (inout [UInt8]) -> Void) -> [UInt8] { var b = base; edit(&b); return b }
        let dib = 22
        #expect(parse([]) == nil)
        #expect(parse([0, 0, 2, 0, 1]) == nil)
        #expect(parse(patched { $0[2] = 3 }) == nil)             // type 3
        #expect(parse(patched { $0[4] = 0 }) == nil)             // count 0
        #expect(parse(patched { $0[4] = 65 }) == nil)            // count 65
        #expect(parse(patched { $0[18] = 0xFF; $0[19] = 0xFF }) == nil)   // offset past the end
        #expect(parse(patched { $0[dib] = 12 }) == nil)          // BITMAPCOREHEADER
        #expect(parse(patched { $0[dib + 14] = 3 }) == nil)      // 3 bits per pixel
        #expect(parse(patched { $0[dib + 16] = 1 }) == nil)      // BI_RLE8
        #expect(parse(patched { $0[dib + 4] = 0 }) == nil)       // width 0
        #expect(parse(patched { $0[dib + 4] = 0x2C; $0[dib + 5] = 0x01 }) == nil)   // width 300
        #expect(parse(patched { $0[dib + 8] = 12 }) == nil)      // height 3x
        #expect(parse(Array(base.prefix(dib + 40 + 16 + 4))) == nil)   // truncated XOR block

        var far = solid24(width: 4, height: 4, bgr: [1, 2, 3])
        far.hotSpot = (40, 40)
        #expect(parse(makeCur(far))?.frames[0].hotSpot == CGPoint(x: 3, y: 3))

        // Seeded single-byte mutations must come back without trapping.
        var lcg = LCG()
        let ani = AniSpec(frames: [cur24(1, 2, 3), cur24(4, 5, 6)], rate: [3, 4], seq: [1, 0]).build()
        for source in [base, ani] {
            for _ in 0..<500 {
                var copy = source
                copy[lcg.next() % copy.count] = UInt8(truncatingIfNeeded: lcg.next())
                _ = parse(copy)
            }
        }
    }

    @Test func aniFramesRatesAndSequenceAreRead() throws {
        let ani = AniSpec(frames: [cur24(255, 0, 0), cur24(0, 255, 0), cur24(0, 0, 255)], rate: [6, 12, 60], seq: [2, 0, 1])
        let cursor = try #require(parse(ani.build()))
        #expect(cursor.frames.count == 3)
        #expect(cursor.steps == [.init(frame: 2, duration: 0.1), .init(frame: 0, duration: 0.2), .init(frame: 1, duration: 1.0)])
        #expect(abs(cursor.cycleDuration - 1.3) < 1e-9)
        #expect(cursor.isAnimated)
        #expect(rgba(cursor.frames[2].image, 0, 0) == [0, 0, 255, 255])
    }

    @Test func aniDefaultsToDisplayRateAndIdentitySequence() throws {
        let two = [cur24(255, 0, 0), cur24(0, 255, 0)]
        #expect(try #require(parse(AniSpec(frames: two).build())).steps == [.init(frame: 0, duration: 1.0 / 6), .init(frame: 1, duration: 1.0 / 6)])
        #expect(try #require(parse(AniSpec(frames: two, dispRate: 0).build())).steps.map(\.duration) == [1.0 / 60, 1.0 / 60])
        #expect(try #require(parse(AniSpec(frames: two, nSteps: 5).build())).steps.count == 2)
        let skipped = try #require(parse(AniSpec(frames: two, seq: [0, 7, 1], nSteps: 3).build()))
        #expect(skipped.steps.map(\.frame) == [0, 1])
    }

    @Test func aniToleratesNestedFramOddChunksAndWrongHeader() throws {
        let big = (0..<3).map { cur24(UInt8($0 * 40), 0, 0, size: 32) }
        let nested = AniSpec(frames: big, nestFramInInfo: true, anihWidth: 0, anihBits: 4)
        let cursor = try #require(parse(nested.build()))
        #expect(cursor.frames.count == 3)
        #expect(cursor.frames[0].image.width == 32 && cursor.frames[0].image.height == 32)

        // wsmin-style: 15 frames, 16 steps, the sequence ends back on frame 0.
        let frames = (0..<15).map { cur24(UInt8($0 * 10), 0, 0) }
        let wsmin = AniSpec(frames: frames, rate: Array(repeating: 5, count: 16), seq: Array(0..<15) + [0], nSteps: 16)
        let steps = try #require(parse(wsmin.build())).steps
        #expect(steps.count == 16)
        #expect(steps.last?.frame == 0)
    }

    @Test func aniRejectsRawFramesAndBrokenFiles() throws {
        let frames = [cur24(1, 0, 0), cur24(2, 0, 0), cur24(3, 0, 0)]
        #expect(parse(AniSpec(frames: frames, flags: 0).build()) == nil)
        #expect(parse(AniSpec(frames: frames, form: "WAVE").build()) == nil)
        #expect(parse(AniSpec(frames: frames, includeAnih: false).build()) == nil)
        #expect(parse(AniSpec(frames: []).build()) == nil)

        let garbage: [UInt8] = Array("garbage!".utf8)
        let partial = try #require(parse(AniSpec(frames: [frames[0], garbage, frames[2]]).build()))
        #expect(partial.frames.count == 2)
        #expect(partial.steps.map(\.frame) == [0, 1])
        #expect(parse(AniSpec(frames: [garbage, garbage]).build()) == nil)

        var trailing = ByteWriter()
        trailing.ascii("junk"); trailing.u32(5000); trailing.append([1, 2, 3, 4])
        #expect(parse(AniSpec(frames: frames, trailing: trailing.bytes).build()) == nil)
    }

    @Test func cursorsLoadByWebampNameOnly() throws {
        let cur = Data(cur24(1, 2, 3))
        let ani = Data(AniSpec(frames: [cur24(1, 0, 0), cur24(2, 0, 0)]).build())
        let archive = SkinArchive(files: ["CLOSE.CUR": cur, "normal.cur": ani, "volbar.cur": cur, "mainmenul.cur": cur, "matrix.cur": cur])
        let cursors = SkinCursors.load(from: archive)
        #expect(Set(cursors.byName.keys) == ["CLOSE", "NORMAL"])
        #expect(cursors["close"] != nil)
        #expect(cursors["normal"]?.isAnimated == true)
        #expect(cursors.unreadable.isEmpty)
        #expect(SkinCursors.names.count == 24)
        #expect(SkinCursors.names.contains("WSPOSBAR"))
        #expect(!SkinCursors.names.contains("VOLBAR"))
    }

    @Test func unreadableCursorsAreReportedNotFatal() throws {
        let cursors = SkinCursors.load(from: SkinArchive(files: ["titlebar.cur": Data("garbage".utf8)]))
        #expect(cursors["TITLEBAR"] == nil)
        #expect(cursors.unreadable == ["titlebar.cur"])

        let main = TestBitmaps.bmp(width: 275, height: 116, fill: RGBColor(red: 1, green: 2, blue: 3))
        let skin = try SkinParser.parse(archive: SkinArchive(files: ["main.bmp": main, "titlebar.cur": Data("garbage".utf8)]))
        let plain = try SkinParser.parse(archive: SkinArchive(files: ["main.bmp": main]))
        #expect(skin.warnings == plain.warnings)   // a bad cursor is cosmetic: no extra warning
        #expect(skin.cursors.unreadable.count == 1)
        #expect(plain.cursors.isEmpty)
    }

    @Test func mainRegionsMatchWebampCSS() {
        func names(_ x: CGFloat, _ y: CGFloat, _ mode: CursorRegions.MainMode = .normal) -> [String] {
            CursorRegions.candidates(at: CGPoint(x: x, y: y), mode: mode)
        }
        #expect(names(8, 5) == ["MAINMENU", "TITLEBAR", "NORMAL"])
        #expect(names(100, 5) == ["TITLEBAR", "NORMAL"])
        #expect(names(248, 5) == ["MIN", "TITLEBAR", "NORMAL"])
        #expect(names(258, 5) == ["WINBUT", "TITLEBAR", "NORMAL"])
        #expect(names(268, 5) == ["CLOSE", "TITLEBAR", "NORMAL"])
        #expect(names(150, 30) == ["SONGNAME", "NORMAL"])
        #expect(names(150, 23) == ["NORMAL"])
        #expect(names(150, 36) == ["NORMAL"])
        #expect(names(20, 75) == ["POSBAR", "NORMAL"])
        #expect(names(110, 60) == ["VOLBAL", "NORMAL"])
        #expect(names(180, 60) == ["VOLBAL", "NORMAL"])
        #expect(names(50, 100) == ["NORMAL"])
        #expect(names(300, 5).isEmpty)
        #expect(names(10, 116).isEmpty)
        #expect(names(8, 5, .shade) == ["MMENU", "MAINMENU", "WSNORMAL", "NORMAL"])
        #expect(names(100, 5, .shade) == ["WSNORMAL", "NORMAL"])
        #expect(names(230, 6, .shade) == ["WSPOSBAR", "POSBAR", "WSNORMAL", "NORMAL"])
        #expect(names(248, 5, .shade) == ["MIN", "WSNORMAL", "NORMAL"])
        #expect(names(100, 20, .shade).isEmpty)
    }

    @Test func regionResolutionFallsThroughTheCascade() {
        func cursors(_ names: [String]) -> SkinCursors {
            let cur = parse(cur24(1, 2, 3))!
            return SkinCursors(byName: Dictionary(uniqueKeysWithValues: names.map { ($0, cur) }), unreadable: [])
        }
        let normalOnly = cursors(["NORMAL"])
        let both = cursors(["NORMAL", "TITLEBAR"])
        let points = [CGPoint(x: 8, y: 5), CGPoint(x: 100, y: 5), CGPoint(x: 150, y: 30), CGPoint(x: 50, y: 100)]
        for point in points {
            #expect(CursorRegions.resolve(at: point, mode: .normal, in: normalOnly) != nil)
            #expect(CursorRegions.resolve(at: point, mode: .normal, in: .empty) == nil)
        }
        #expect(CursorRegions.resolve(at: CGPoint(x: 300, y: 5), mode: .normal, in: normalOnly) == nil)
        // TITLEBAR is the first candidate the skin has at (8, 5) and (100, 5); (50, 100) has only NORMAL.
        #expect(CursorRegions.candidates(at: CGPoint(x: 8, y: 5), mode: .normal).first(where: { both[$0] != nil }) == "TITLEBAR")
        #expect(CursorRegions.candidates(at: CGPoint(x: 50, y: 100), mode: .normal).first(where: { both[$0] != nil }) == "NORMAL")
        #expect(CursorRegions.regionKey(at: CGPoint(x: 8, y: 5), mode: .normal) == "MAINMENU")
        #expect(CursorRegions.regionKey(at: CGPoint(x: 100, y: 5), mode: .normal) == "TITLEBAR")
        #expect(CursorRegions.regionKey(at: CGPoint(x: 300, y: 5), mode: .normal) == "")
    }

    @Test func equalizerRegionsMatchWebampCSS() {
        func names(_ x: CGFloat, _ y: CGFloat, shaded: Bool = false) -> [String] {
            CursorRegions.candidates(at: CGPoint(x: x, y: y), window: .equalizer(shaded: shaded))
        }
        #expect(names(100, 5) == ["EQTITLE", "EQNORMAL", "NORMAL"])
        #expect(names(268, 5) == ["EQCLOSE", "EQTITLE", "EQNORMAL", "NORMAL"])
        #expect(names(258, 5) == ["EQTITLE", "EQNORMAL", "NORMAL"])   // the shade button has no rule of its own
        #expect(names(80, 60) == ["EQSLID", "EQNORMAL", "NORMAL"])
        #expect(names(25, 60) == ["EQSLID", "EQNORMAL", "NORMAL"])    // the preamp is a band
        #expect(names(94, 60) == ["EQNORMAL", "NORMAL"])              // the 4-px gap between bands
        #expect(names(10, 100) == ["EQNORMAL", "NORMAL"])
        #expect(names(150, 5, shaded: true) == ["EQTITLE", "EQNORMAL", "NORMAL"])
        #expect(names(268, 5, shaded: true) == ["EQCLOSE", "EQTITLE", "EQNORMAL", "NORMAL"])
        #expect(names(150, 20, shaded: true).isEmpty)
        #expect(names(300, 5).isEmpty)
    }

    @Test func playlistRegionsMatchWebampCSS() {
        let steps = PlaylistLayout.Steps(width: 2, height: 1)   // 325 x 145
        func names(_ x: CGFloat, _ y: CGFloat, shaded: Bool = false) -> [String] {
            CursorRegions.candidates(at: CGPoint(x: x, y: y), window: .playlist(steps, shaded: shaded))
        }
        #expect(names(100, 5) == ["PTBAR", "PNORMAL", "NORMAL"])
        #expect(names(325 - 6, 6) == ["PCLOSE", "PTBAR", "PNORMAL", "NORMAL"])
        #expect(names(325 - 16, 6) == ["PWINBUT", "PTBAR", "PNORMAL", "NORMAL"])
        #expect(names(100, 60) == ["PNORMAL", "NORMAL"])
        #expect(names(325 - 15, 60) == ["PVSCROLL", "PNORMAL", "NORMAL"])
        #expect(names(325 - 5, 145 - 5) == ["PSIZE", "PNORMAL", "NORMAL"])
        #expect(names(400, 5).isEmpty)
        #expect(names(100, 5, shaded: true) == ["PWSNORM", "NORMAL"])
        #expect(names(325 - 6, 6, shaded: true) == ["PCLOSE", "PWSNORM", "NORMAL"])
        #expect(names(325 - 16, 6, shaded: true) == ["PWINBUT", "PWSNORM", "NORMAL"])
        #expect(names(325 - 25, 6, shaded: true) == ["PWSSIZE", "PWSNORM", "NORMAL"])
        #expect(names(100, 20, shaded: true).isEmpty)
    }

    @Test func frameUpscalesWithNearestNeighbour() throws {
        let spec = CurSpec(width: 2, height: 2, xorRows: [[0, 0, 255, 0, 255, 0], [255, 0, 0, 255, 255, 255]])
        let frame = try #require(parse(makeCur(spec))).frames[0]
        let big = try #require(frame.upscaled(2))
        #expect(big.width == 4 && big.height == 4)
        #expect(rgba(big, 0, 0) == rgba(frame.image, 0, 0))
        #expect(rgba(big, 1, 1) == rgba(frame.image, 0, 0))
        #expect(rgba(big, 2, 1) == rgba(frame.image, 1, 0))
        #expect(rgba(big, 3, 3) == rgba(frame.image, 1, 1))
    }
}
