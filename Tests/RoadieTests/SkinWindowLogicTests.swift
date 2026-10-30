import CoreGraphics
import Foundation
import SkinBrowser
import SkinLibrary
import XCTest

@testable import Roadie

/// #0217: the skins folder's index text, `addDownloaded`, and the main menu's skin navigation, on a temp folder of
/// generated skins (no test-skin cache, no network).
extension SkinLibraryModelTests {
    func testCountsTextBeforeAndAfterScan() async throws {
        let configuration = try testConfiguration()
        let folder = try seededSkinsFolder()
        configuration.defaults.set(folder.path, forKey: SkinLibraryModel.folderKey)
        let library = SkinLibraryModel(
            defaults: configuration.defaults,
            databaseURL: try XCTUnwrap(configuration.dataDirectory).appending(path: "skins.sqlite"),
            startupDelay: .seconds(3600))
        XCTAssertTrue(library.hasFolder)
        XCTAssertEqual(library.countsText, "Not indexed yet")
        XCTAssertNil(library.statusText)

        library.scan()
        try await waitUntil("the first pass") { !library.isIndexing && library.counts != nil }
        let counts = try XCTUnwrap(library.counts)
        // Three distinct skins, a byte-identical copy of one of them, and one unreadable file.
        XCTAssertEqual(counts.files, 5)
        XCTAssertEqual(counts.skins, 4)
        XCTAssertEqual(library.countsText, "4 skins in 5 files")
        let ok = counts.byStatus[.ok] ?? 0
        let partial = counts.byStatus[.partial] ?? 0
        XCTAssertEqual(ok + partial, 3)
        XCTAssertEqual(counts.byStatus[.failed], 1)
        XCTAssertEqual(library.statusText, "\(ok) ok, \(partial) partial, 1 failed")
        XCTAssertNil(library.errorMessage)
    }

    func testAddDownloadedIndexesOnlyInsideFolder() async throws {
        let configuration = try testConfiguration()
        let folder = try temporaryDirectory("roadie-skins")
        let library = SkinLibraryModel(
            defaults: configuration.defaults,
            databaseURL: try XCTUnwrap(configuration.dataDirectory).appending(path: "skins.sqlite"),
            startupDelay: .seconds(3600))
        library.setFolder(folder.path)
        try await waitUntil("the empty folder's pass") { !library.isIndexing && library.counts != nil }
        XCTAssertEqual(library.counts?.files, 0)

        let outside = try makeDistinctSkin(named: "Outside", in: try temporaryDirectory("roadie-outside"))
        await library.addDownloaded(outside)
        XCTAssertFalse(library.isIndexing)
        XCTAssertEqual(library.counts?.files, 0, "a file outside the skins folder was indexed")

        let museum = folder.appending(path: "Museum", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: museum, withIntermediateDirectories: true)
        let inside = try makeDistinctSkin(named: "Inside", in: museum)
        await library.addDownloaded(inside)
        XCTAssertFalse(library.isIndexing, "addDownloaded fell back to a full pass")
        XCTAssertEqual(library.counts?.files, 1)
        XCTAssertEqual(library.counts?.skins, 1)
    }

    func testMainMenuNextPreviousRandomSkin() async throws {
        let model = try makeModel()
        let folder = try seededSkinsFolder()
        model.skinLibrary.setFolder(folder.path)
        try await waitUntil("the first pass") { !model.skinLibrary.isIndexing && model.skinLibrary.counts != nil }
        let browser = model.skinBrowser
        XCTAssertNil(browser.currentSkinID)

        // Random from no current skin applies one of the loadable skins.
        model.perform(.randomSkin)
        try await waitUntil("random skin") { browser.currentSkinID != nil }
        let picked = try XCTUnwrap(browser.currentSkinID)

        // Three nexts visit the other two loadable skins and wrap back to the pick (the failed one is skipped).
        var ids: [Int64] = []
        for step in 0..<3 {
            let before = browser.currentSkinID
            model.perform(.nextSkin)
            try await waitUntil("next skin \(step)") { browser.currentSkinID != before }
            ids.append(try XCTUnwrap(browser.currentSkinID))
        }
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(ids[2], picked, "next didn't wrap after the last loadable skin")

        // Previous steps back the same way, wrapping too.
        model.perform(.previousSkin)
        try await waitUntil("previous skin") { browser.currentSkinID == ids[1] }
        model.perform(.previousSkin)
        try await waitUntil("previous again") { browser.currentSkinID == ids[0] }
        model.perform(.previousSkin)
        try await waitUntil("previous wraps") { browser.currentSkinID == picked }

        // Random can still pick the skin already showing (SkinIndexStore.randomSkin is `ORDER BY random()`): #0256
        // adds an injectable random source and a strict test for that.
    }

    // MARK: Helpers

    /// Alpha, Bravo and Charlie (distinct), a byte-identical copy of Alpha, and one file that isn't a zip.
    func seededSkinsFolder() throws -> URL {
        let folder = try temporaryDirectory("roadie-skins")
        let alpha = try makeDistinctSkin(named: "Alpha", in: folder)
        _ = try makeDistinctSkin(named: "Bravo", in: folder)
        _ = try makeDistinctSkin(named: "Charlie", in: folder)
        try FileManager.default.copyItem(at: alpha, to: folder.appending(path: "Alpha copy.wsz"))
        try Data("not a zip".utf8).write(to: folder.appending(path: "Junk.wsz"))
        return folder
    }

    /// A one-sheet `.wsz` whose bytes differ from every other (a readme names it), so the index keeps it apart.
    func makeDistinctSkin(named name: String, in folder: URL) throws -> URL {
        let content = try temporaryDirectory("roadie-skin-\(name)")
        try Self.bmp(width: 275, height: 116).write(to: content.appending(path: "main.bmp"))
        try Data("\(name) \(UUID())".utf8).write(to: content.appending(path: "readme.txt"))
        let wsz = folder.appending(path: "\(name).wsz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--norsrc", "--noextattr", content.path, wsz.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return wsz
    }
}

/// A thumbnail provider that renders nothing; these tests never draw a cell.
struct NoThumbnails: SkinThumbnailProviding {
    func thumbnail(for record: SkinRecord, at url: URL) async -> CGImage? { nil }
    func remove(hash: String) async {}
}

/// #0217: what the Skins window's and the Museum tab's status areas and grid footers show.
@MainActor
final class SkinWindowContentTests: PlayerModelTestCase {
    struct IndexFailure: LocalizedError {
        var errorDescription: String? { "The index is unreadable." }
    }

    func testSkinsStatusContent() async throws {
        XCTAssertEqual(SkinBrowserStatusContent.content(for: .needsFolder), .needsFolder)
        XCTAssertEqual(SkinBrowserStatusContent.content(for: .failed("Broken")), .failed("Broken"))
        for phase: SkinBrowserPhase in [.idle, .loading, .loaded] {
            XCTAssertEqual(SkinBrowserStatusContent.content(for: phase), .progress, "\(phase)")
        }

        // A model with no skins folder: its index is missing, so the window asks for a folder.
        let model = try makeModel()
        XCTAssertFalse(model.skinLibrary.hasFolder)
        model.skinBrowser.appeared()
        try await waitUntil("needs folder") { model.skinBrowser.phase == .needsFolder }
        XCTAssertEqual(SkinBrowserStatusContent.content(for: model.skinBrowser.phase), .needsFolder)

        // An index that can't be opened: the failure and its message.
        let broken = SkinBrowserModel(
            index: { throw IndexFailure() }, folder: { nil }, thumbnails: NoThumbnails(), applySkin: { _ in })
        broken.appeared()
        try await waitUntil("failed") { broken.phase != .idle }
        XCTAssertEqual(SkinBrowserStatusContent.content(for: broken.phase), .failed("The index is unreadable."))
    }

    func testMuseumStatusContent() {
        func content(_ phase: MuseumBrowserPhase, empty: Bool = true, search: String = "") -> MuseumStatusContent {
            MuseumStatusContent.content(for: phase, isEmpty: empty, searchText: search)
        }
        XCTAssertEqual(content(.idle), .loading)
        XCTAssertEqual(content(.loading), .loading)
        XCTAssertEqual(content(.offline("No network")), .offline("No network"))
        XCTAssertEqual(content(.failed("HTTP 500")), .failed("HTTP 500"))
        XCTAssertEqual(content(.loaded), .noSkins)
        XCTAssertEqual(content(.loaded, search: "  \n"), .noSkins)
        XCTAssertEqual(content(.loaded, search: "  llama "), .noResults("llama"))
        XCTAssertEqual(content(.loaded, empty: false), .grid)
        XCTAssertEqual(content(.loaded, empty: false, search: "llama"), .grid)
        // Offline wins over a search with no items.
        XCTAssertEqual(content(.offline("No network"), search: "llama"), .offline("No network"))

        XCTAssertTrue(MuseumStatusContent.showsFolderPrompt(hasFolder: false))
        XCTAssertFalse(MuseumStatusContent.showsFolderPrompt(hasFolder: true))
    }

    func testGridFooterContent() {
        XCTAssertEqual(GridFooterContent.content(loadMoreError: nil, isLoadingMore: false), .nothing)
        XCTAssertEqual(GridFooterContent.content(loadMoreError: nil, isLoadingMore: true), .loading)
        XCTAssertEqual(GridFooterContent.content(loadMoreError: "Timed out", isLoadingMore: false), .error("Timed out"))
        XCTAssertEqual(GridFooterContent.content(loadMoreError: "Timed out", isLoadingMore: true), .error("Timed out"))
    }
}
