import AppKit
import MusicBackendKit
import XCTest

@testable import Roadie

/// `LibraryDropDecoder` (#0184, #0188, #0210) against real, uniquely named `NSPasteboard`s (never the general or
/// drag pasteboard), released in `tearDown`.
@MainActor
final class DropDecoderTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() async throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("roadie.tests.\(UUID())"))
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private let type = LibraryDropDecoder.mediaIDType

    private func data(_ ids: [MediaID]) throws -> Data { try JSONEncoder().encode(MediaIDTransfer(ids)) }

    private func item(_ ids: [MediaID]) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(try data(ids), forType: type))
        return item
    }

    /// Supplies the media-id data only when asked (as a SwiftUI drag source can), or nothing.
    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        let data: Data?
        var calls = 0
        init(_ data: Data?) { self.data = data }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            calls += 1
            if let data { item.setData(data, forType: type) }
        }
    }

    // MARK: Media ids

    /// #0188: a SwiftUI multi-item drag puts each item on its own pasteboard item; every one is read, in order.
    func testReadsEveryPasteboardItem() throws {
        let pasteboard = makePasteboard()
        let a = MediaID(.album, "Artist/Album A")
        let b = MediaID(.track, "Artist/Album A/01.mp3")
        let c = MediaID(.artist, "Other")
        let d = MediaID(.album, "Other/Singles")
        XCTAssertTrue(pasteboard.writeObjects([try item([a]), try item([b, c]), try item([d])]))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 3)
        XCTAssertTrue(LibraryDropDecoder.hasMediaID(pasteboard))
        XCTAssertEqual(LibraryDropDecoder.mediaIDs(from: pasteboard), [a, b, c, d])
    }

    func testReadsLazilyProvidedData() throws {
        let pasteboard = makePasteboard()
        let id = MediaID(.album, "Lazy/Album")
        let provider = Provider(try data([id]))
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertTrue(LibraryDropDecoder.hasMediaID(pasteboard))
        XCTAssertEqual(LibraryDropDecoder.mediaIDs(from: pasteboard), [id])
        XCTAssertGreaterThan(provider.calls, 0, "the provider was asked for the data")
    }

    func testFallsBackToThePasteboardData() throws {
        let pasteboard = makePasteboard()
        let id = MediaID(.track, "Fallback/01.mp3")
        pasteboard.declareTypes([type], owner: nil)
        XCTAssertTrue(pasteboard.setData(try data([id]), forType: type))
        XCTAssertTrue(LibraryDropDecoder.hasMediaID(pasteboard))
        XCTAssertEqual(LibraryDropDecoder.mediaIDs(from: pasteboard), [id])
    }

    /// The notice path: the type is declared but no data comes back.
    func testTypePresentButNoDataIsNil() throws {
        let pasteboard = makePasteboard()
        let provider = Provider(nil)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertTrue(LibraryDropDecoder.hasMediaID(pasteboard))
        XCTAssertNil(LibraryDropDecoder.mediaIDs(from: pasteboard))
    }

    func testUndecodableDataIsNil() {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(Data("not json".utf8), forType: type)
        pasteboard.writeObjects([item])
        XCTAssertNil(LibraryDropDecoder.mediaIDs(from: pasteboard))
    }

    func testHasMediaIDLooksAtItemsToo() throws {
        let plain = makePasteboard()
        plain.setString("hello", forType: .string)
        XCTAssertFalse(LibraryDropDecoder.hasMediaID(plain))

        // A second item carries the type; the first doesn't.
        let mixed = makePasteboard()
        let text = NSPasteboardItem()
        text.setString("hello", forType: .string)
        XCTAssertTrue(mixed.writeObjects([text, try item([MediaID(.album, "A/B")])]))
        XCTAssertTrue(mixed.pasteboardItems?.first?.types.contains(type) == false)
        XCTAssertTrue(LibraryDropDecoder.hasMediaID(mixed))
    }

    // MARK: Operation

    func testOperationPrefersCopyThenGenericThenMove() {
        XCTAssertEqual(LibraryDropDecoder.operation(for: [.copy, .generic, .move]), .copy)
        XCTAssertEqual(LibraryDropDecoder.operation(for: .every), .copy)
        XCTAssertEqual(LibraryDropDecoder.operation(for: [.generic, .move]), .generic)
        XCTAssertEqual(LibraryDropDecoder.operation(for: [.move, .link]), .move)
    }

    func testOperationIsEmptyForAnUnrelatedMask() {
        XCTAssertEqual(LibraryDropDecoder.operation(for: [.link]), [])
        XCTAssertEqual(LibraryDropDecoder.operation(for: [.delete, .private]), [])
        XCTAssertEqual(LibraryDropDecoder.operation(for: []), [])
    }

    // MARK: File URLs

    /// The decoder returns every file URL in order, audio or not; `PlayerModel.open` filters them.
    func testFileURLsAreReadInOrderAndNonAudioIsKept() {
        let pasteboard = makePasteboard()
        let urls = [
            URL(fileURLWithPath: "/nonexistent/roadie-tests/b.mp3"),
            URL(fileURLWithPath: "/nonexistent/roadie-tests/notes.txt"),
            URL(fileURLWithPath: "/nonexistent/roadie-tests/a.flac"),
        ]
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]))
        XCTAssertTrue(LibraryDropDecoder.hasFileURLs(pasteboard))
        XCTAssertFalse(LibraryDropDecoder.hasMediaID(pasteboard))
        XCTAssertEqual(LibraryDropDecoder.fileURLs(from: pasteboard).map(\.path), urls.map(\.path))
    }

    // MARK: Drop plan (#0228)

    func testPlanForAnOptionDragIsCopyWithTheReplaceCue() throws {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([try item([MediaID(.album, "a")])]))
        let replacing = try XCTUnwrap(LibraryDropDecoder.plan(pasteboard: pasteboard, mask: .copy, replacing: true))
        XCTAssertEqual(replacing.operation, .copy)
        XCTAssertEqual(replacing.cue, .replace)
        let plain = try XCTUnwrap(LibraryDropDecoder.plan(pasteboard: pasteboard, mask: .copy, replacing: false))
        XCTAssertEqual(plain.operation, .copy)
        XCTAssertNil(plain.cue)
    }

    func testPlanForFilesWithOptionHasTheReplaceCue() throws {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([URL(fileURLWithPath: "/nonexistent/roadie-tests/a.mp3") as NSURL]))
        let plan = try XCTUnwrap(LibraryDropDecoder.plan(pasteboard: pasteboard, mask: .copy, replacing: true))
        XCTAssertEqual(plan.operation, .copy)
        XCTAssertEqual(plan.cue, .replace)
    }

    func testPlanForAnUnrelatedPasteboardIsNil() throws {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([URL(string: "https://roadie.sstools.co/")! as NSURL]))
        XCTAssertNil(LibraryDropDecoder.plan(pasteboard: pasteboard, mask: .every, replacing: true))
        let ids = makePasteboard()
        XCTAssertTrue(ids.writeObjects([try item([MediaID(.album, "a")])]))
        XCTAssertNil(LibraryDropDecoder.plan(pasteboard: ids, mask: .link, replacing: true), "no cue for a refused drag")
    }

    func testWebURLsAreNotFileURLs() {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([URL(string: "https://roadie.sstools.co/")! as NSURL]))
        XCTAssertFalse(LibraryDropDecoder.hasFileURLs(pasteboard))
        XCTAssertTrue(LibraryDropDecoder.fileURLs(from: pasteboard).isEmpty)
    }
}
