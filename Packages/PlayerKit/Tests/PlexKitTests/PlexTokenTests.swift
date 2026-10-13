import Testing
import PlexKit

struct PlexTokenTests {
    @Test func tokenPrintsRedacted() {
        let raw = "super-secret-token-value"
        let token = PlexToken(raw)
        #expect(!"\(token)".contains(raw))
        #expect(!String(reflecting: token).contains(raw))
        #expect(!String(describing: token).contains(raw))
        #expect(Mirror(reflecting: token).children.isEmpty)
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains(raw))
        #expect(token.rawValue == raw)
    }
}
