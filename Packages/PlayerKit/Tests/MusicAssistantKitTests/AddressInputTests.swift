import Foundation
import Testing
@testable import MusicAssistantKit

private func parsed(_ text: String) -> String? {
    if case .success(let url) = MusicAssistantAddressInput.parse(text) { return url.absoluteString }
    return nil
}

private func problem(_ text: String) -> MusicAssistantAddressInput.Problem? {
    if case .failure(let problem) = MusicAssistantAddressInput.parse(text) { return problem }
    return nil
}

struct AddressInputTests {
    @Test func bareLocalHostGetsHTTPAndPort8095() {
        #expect(parsed("ma.local") == "http://ma.local:8095")
        #expect(parsed("nas") == "http://nas:8095")
        #expect(parsed("192.168.1.5") == "http://192.168.1.5:8095")
        #expect(parsed("100.101.102.103") == "http://100.101.102.103:8095")
    }

    @Test func aBareNonLocalHostDefaultsToHTTPS() {
        #expect(parsed("music.example.test") == "https://music.example.test")
        #expect(parsed("box.tail1234.ts.net") == "https://box.tail1234.ts.net")
        #expect(parsed("music.example.test:8443") == "https://music.example.test:8443")
    }

    @Test func explicitPortIsKept() {
        #expect(parsed("ma.local:9000") == "http://ma.local:9000")
        #expect(parsed("http://100.64.0.1:9000") == "http://100.64.0.1:9000")
        #expect(parsed("https://music.example.test:8443") == "https://music.example.test:8443")
    }

    @Test func httpsWithoutPortKeepsTheDefaultPort() {
        #expect(parsed("https://music.example.test") == "https://music.example.test")
        #expect(parsed("https://ma.local") == "https://ma.local")
    }

    @Test func wsSchemesMapToHTTP() {
        #expect(parsed("ws://ma.local:8095") == "http://ma.local:8095")
        #expect(parsed("wss://music.example.test") == "https://music.example.test")
    }

    @Test func pathIsKeptQueryAndFragmentDropped() {
        #expect(parsed("https://music.example.test/ma/?a=1#frag") == "https://music.example.test/ma")
        #expect(parsed("https://music.example.test/") == "https://music.example.test")
        #expect(parsed("ma.local/prefix?x=1") == "http://ma.local:8095/prefix")
    }

    @Test func bracketedIPv6WithPort() {
        #expect(parsed("[::1]:9000") == "http://[::1]:9000")
        #expect(parsed("[::1]") == "http://[::1]:8095")
        #expect(parsed("http://[fd7a:115c:a1e0::1]") == "http://[fd7a:115c:a1e0::1]:8095")
    }

    @Test func whitespaceIsTrimmedAndSchemeAndHostLowercased() {
        #expect(parsed("  HTTPS://Music.Example.TEST  ") == "https://music.example.test")
        #expect(parsed("\n MA.Local:8095 ") == "http://ma.local:8095")
    }

    @Test func plainHTTPToANonLocalAddressNeedsHTTPS() {
        let message = "Use https for this address; plain http works only on the local network."
        for text in ["http://music.example.test", "http://box.tail1234.ts.net:8095", "ws://music.example.test"] {
            #expect(problem(text) == .httpsRequired)
        }
        #expect(MusicAssistantAddressInput.Problem.httpsRequired.message == message)
        #expect(parsed("http://music.example.test") == nil)
    }

    @Test func emptyInvalidCredentialsAndUnsupportedSchemeAreRejected() {
        #expect(problem("") == .empty)
        #expect(problem("   ") == .empty)
        for text in ["ma local", "ma.local:abc", "ma.local:99999", "ma.local:0", "ma.local:8095:1", "://x", "[::1", "-bad.local"] {
            #expect(problem(text) == .invalid, "\(text)")
        }
        #expect(problem("ftp://ma.local") == .unsupportedScheme)
        #expect(problem("http://user:pw@ma.local") == .credentialsNotAllowed)
        #expect(problem("https://user@music.example.test") == .credentialsNotAllowed)
    }

    @Test func everyProblemHasAMessageThatNamesNoAddress() {
        let all: [MusicAssistantAddressInput.Problem] = [.empty, .invalid, .unsupportedScheme, .credentialsNotAllowed, .httpsRequired]
        for problem in all { #expect(!problem.message.isEmpty) }
    }
}

struct AddressSecurityTests {
    private func classify(_ text: String) -> MusicAssistantAddressSecurity {
        MusicAssistantAddressSecurity.classify(URL(string: text)!)
    }

    @Test func httpsIsEncrypted() {
        #expect(classify("https://music.example.test") == .encrypted)
        #expect(classify("https://box.tail1234.ts.net") == .encrypted)
        #expect(classify("https://ma.local:8443") == .encrypted)
        #expect(classify("wss://music.example.test") == .encrypted)
    }

    @Test func localNamesAndEveryIPAddressAreLocal() {
        let local = [
            "http://ma.local:8095", "http://MA.LOCAL", "http://nas:8095", "http://10.0.0.5:8095", "http://172.16.0.1",
            "http://172.32.0.1", "http://192.168.1.2", "http://169.254.1.1", "http://127.0.0.1", "http://[::1]:8095",
            "http://[fe80::1]", "http://8.8.8.8:8095",
        ]
        for text in local { #expect(classify(text) == .local, "\(text)") }
    }

    @Test func tailscaleIPsAreIPAddressesSoHTTPIsAllowed() {
        for text in ["http://100.64.0.1:8095", "http://100.127.255.254", "http://100.101.102.103:8095", "http://[fd7a:115c:a1e0::1]"] {
            #expect(classify(text) == .local, "\(text)")
        }
    }

    @Test func magicDNSAndPublicNamesOverHTTPNeedTLS() {
        for text in [
            "http://box.tail1234.ts.net:8095", "http://music.example.test:8095", "http://example.com", "http://1.2.3.example.com",
            "http://256.1.1.1",
        ] {
            #expect(classify(text) == .requiresTLS, "\(text)")
        }
    }
}
