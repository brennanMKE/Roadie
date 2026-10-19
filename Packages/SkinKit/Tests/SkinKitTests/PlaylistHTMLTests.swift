import Foundation
import Testing
@testable import SkinKit

@Suite struct PlaylistHTMLTests {
    @Test func escapesMarkup() {
        let html = PlaylistHTML.document(entries: [.init(name: "<b>&\"'", duration: 1)])
        #expect(html.contains("&lt;b&gt;&amp;&quot;&#39;"))
        #expect(!html.contains("<b>"))
    }

    @Test func countsAndTotals() {
        let html = PlaylistHTML.document(entries: [
            .init(name: "a", duration: 60), .init(name: "b", duration: nil), .init(name: "c", duration: 120),
        ])
        #expect(html.contains("<span class=\"t\">3</span> tracks"))
        #expect(html.contains("Playlist length: <span class=\"t\">3:00</span>"))
        #expect(html.contains("average track length: <span class=\"t\">1:30</span>"))
    }

    @Test func emptyPlaylist() {
        let html = PlaylistHTML.document(entries: [])
        #expect(html.contains("<span class=\"t\">0</span> tracks"))
        #expect(html.contains("0:00"))
    }

    @Test func numbersEntriesInOrder() {
        let html = PlaylistHTML.document(entries: [.init(name: "x", duration: 61), .init(name: "y", duration: nil)])
        let first = html.range(of: "<li>1. x (1:01)</li>")
        let second = html.range(of: "<li>2. y</li>")
        #expect(first != nil && second != nil)
        if let first, let second { #expect(first.lowerBound < second.lowerBound) }
    }
}
