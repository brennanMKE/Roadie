import Foundation
import MusicAssistantKitStub
import Security
import Testing
@testable import MusicAssistantKit

struct TokenStoreTests {
    @Test func inMemoryStoreLoadsSavesAndDeletes() throws {
        let store = InMemoryMusicAssistantTokenStore()
        #expect(try store.load() == nil)
        try store.save(testToken)
        #expect(try store.load() == testToken)
        try store.delete()
        #expect(try store.load() == nil)
        #expect(store.loads == 3)
        #expect(store.saves == 1)
        #expect(store.deletes == 1)
    }

    @Test func aFailingStoreThrowsWithoutTheToken() throws {
        let store = InMemoryMusicAssistantTokenStore(token: testToken)
        store.failure = .keychain(-25300)
        do {
            _ = try store.load()
            Issue.record("expected a throw")
        } catch let error as MusicAssistantTokenStoreError {
            #expect(error == .keychain(-25300))
            #expect(!(error.errorDescription ?? "").contains("ma-UNIT-TEST-TOKEN"))
            #expect(!String(describing: error).contains("ma-UNIT-TEST-TOKEN"))
        }
        #expect(!String(describing: store).contains("ma-UNIT-TEST-TOKEN"))
    }

    @Test func keychainStoreUsesOneItemPerAccount() {
        let a = KeychainMusicAssistantTokenStore(account: "a")
        let b = KeychainMusicAssistantTokenStore(account: "b")
        // Only the query dictionaries are compared: no Keychain call is made.
        #expect(a.baseQuery[kSecAttrAccount as String] as? String == "a")
        #expect(b.baseQuery[kSecAttrAccount as String] as? String == "b")
        #expect(a.baseQuery[kSecAttrService as String] as? String == "co.sstools.roadie.musicAssistant")
        #expect(a.baseQuery[kSecAttrService as String] as? String == b.baseQuery[kSecAttrService as String] as? String)
    }

    @Test func inMemoryExistsDoesNotCountAsALoad() throws {
        let store = InMemoryMusicAssistantTokenStore()
        #expect(try store.exists() == false)
        try store.save(testToken)
        #expect(try store.exists() == true)
        #expect(store.existsChecks == 2)
        #expect(store.loads == 0)
        store.failExists = -25308
        #expect(throws: MusicAssistantTokenStoreError.keychain(-25308)) { try store.exists() }
        #expect(store.token == testToken)
    }
}
