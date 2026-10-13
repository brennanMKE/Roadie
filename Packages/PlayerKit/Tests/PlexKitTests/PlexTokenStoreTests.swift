import Foundation
import Testing
import PlexKit
import PlexKitStub

struct PlexTokenStoreTests {
    static let secret = "tok-UNIT-TEST-SECRET-0123"

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryPlexTokenStore()
        #expect(try store.load() == nil)
        try store.save(PlexToken("one"))
        #expect(try store.load() == PlexToken("one"))
        try store.save(PlexToken("two"))
        #expect(try store.load() == PlexToken("two"))
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
        #expect(store.loads == 4)
        #expect(store.saves == 2)
        #expect(store.deletes == 2)
    }

    @Test func inMemoryStoreFailurePropagates() {
        let store = InMemoryPlexTokenStore(token: PlexToken(Self.secret))
        store.failure = .keychain(-25300)
        #expect(throws: PlexTokenStoreError.keychain(-25300)) { _ = try store.load() }
        #expect(throws: PlexTokenStoreError.keychain(-25300)) { try store.save(PlexToken("x")) }
        #expect(throws: PlexTokenStoreError.keychain(-25300)) { try store.delete() }
        let text = PlexTokenStoreError.keychain(-25300).errorDescription ?? ""
        #expect(text.contains("-25300"))
        #expect(!text.contains(Self.secret))
    }

    @Test func storesNeverPrintTheToken() {
        let store = InMemoryPlexTokenStore(token: PlexToken(Self.secret))
        var dumped = ""
        dump(store, to: &dumped)
        for text in [String(describing: store), String(reflecting: store), dumped] {
            #expect(!text.contains(Self.secret))
        }
    }
}

/// Opt-in, host only: the real Keychain. The VM never sets the variable, so a headless guest
/// never meets an access-control dialog. Uses a unique service so the app's own item is untouched.
struct KeychainPlexTokenStoreTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PLEX_KEYCHAIN_TEST"] == "1"))
    func keychainRoundTrip() throws {
        let store = KeychainPlexTokenStore(service: "com.brennanmke.SkinAmp.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        try store.save(PlexToken("first"))
        #expect(try store.load() == PlexToken("first"))
        try store.save(PlexToken("second"))
        #expect(try store.load() == PlexToken("second"))
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}
