import Foundation
import Testing

@testable import SkinBrowser

@Suite struct SkinBrowserFormatTests {
    @Test func countLabelCoversFilteredUnfilteredAndEmpty() {
        #expect(SkinBrowserFormat.countLabel(matching: 1234, total: 98765, isFiltered: true) == "1,234 of 98,765 skins")
        #expect(SkinBrowserFormat.countLabel(matching: 98765, total: 98765, isFiltered: false) == "98,765 skins")
        #expect(SkinBrowserFormat.countLabel(matching: nil, total: 98765, isFiltered: false) == "98,765 skins")
        #expect(SkinBrowserFormat.countLabel(matching: 0, total: 50, isFiltered: true) == "No skins")
        #expect(SkinBrowserFormat.countLabel(matching: nil, total: 0, isFiltered: false) == "No skins")
        #expect(SkinBrowserFormat.countLabel(matching: nil, total: nil, isFiltered: false) == "")
    }

    @Test func elapsedLabelRoundsToMilliseconds() {
        #expect(SkinBrowserFormat.elapsedLabel(.milliseconds(12)) == "12 ms")
        #expect(SkinBrowserFormat.elapsedLabel(.microseconds(1200)) == "1 ms")
        #expect(SkinBrowserFormat.elapsedLabel(.seconds(2)) == "2000 ms")
        #expect(SkinBrowserFormat.elapsedLabel(nil) == nil)
    }

    @Test func relativePathIsNilOutsideTheFolderAndStripsTheRoot() {
        let folder = URL(filePath: "/skins", directoryHint: .isDirectory)
        #expect(SkinBrowserFormat.relativePath(of: URL(filePath: "/skins/a/b.wsz"), in: folder) == "a/b.wsz")
        #expect(SkinBrowserFormat.relativePath(of: URL(filePath: "/other/b.wsz"), in: folder) == nil)
        #expect(SkinBrowserFormat.relativePath(of: URL(filePath: "/skins-extra/b.wsz"), in: folder) == nil)
        #expect(SkinBrowserFormat.relativePath(of: folder, in: folder) == nil)
        #expect(SkinBrowserFormat.fileURL(folder: folder, path: "a/b.wsz").path == "/skins/a/b.wsz")
    }
}
