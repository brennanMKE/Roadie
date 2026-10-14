import Foundation
import Testing
@testable import MusicBackendKit

struct PagingTests {
    @Test func makeUsesTheTotalWhenKnown() {
        let page = Page<Int>.make(items: [1, 2, 3], request: PageRequest(offset: 0, limit: 100), total: 242)
        #expect(page.nextOffset == 3)
        #expect(page.hasMore)
        #expect(page.total == 242)
        let last = Page<Int>.make(items: [1, 2], request: PageRequest(offset: 240, limit: 100), total: 242)
        #expect(last.nextOffset == nil)
        #expect(!last.hasMore)
        #expect(last.offset == 240)
    }

    @Test func makeUsesTheLimitWhenTotalIsUnknown() {
        let full = Page<Int>.make(items: [1, 2, 3], request: PageRequest(offset: 0, limit: 3), total: nil)
        #expect(full.nextOffset == 3)
        let short = Page<Int>.make(items: [1, 2], request: PageRequest(offset: 0, limit: 3), total: nil)
        #expect(short.nextOffset == nil)
        #expect(short.total == nil)
    }

    @Test func lastPageHasNoNext() {
        let page = Page<Int>.last([1, 2, 3])
        #expect(page.nextOffset == nil)
        #expect(page.total == 3)
        #expect(page.offset == 0)
        #expect(page.next(limit: 10) == nil)
    }

    @Test func nextCarriesTheLimit() {
        let page = Page<Int>.make(items: [1, 2, 3], request: PageRequest(offset: 20, limit: 3), total: 100)
        #expect(page.next(limit: 50) == PageRequest(offset: 23, limit: 50))
    }
}
