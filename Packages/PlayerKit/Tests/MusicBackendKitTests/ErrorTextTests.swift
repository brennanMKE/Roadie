import Foundation
import Testing
@testable import MusicBackendKit

struct ErrorTextTests {
    @Test func errorDescriptionsNameTheFailure() {
        let cases: [(MusicBackendError, String)] = [
            (.notConfigured("Add a server."), "Add a server."),
            (.notConnected, "Not connected"),
            (.unreachable("Server down"), "Server down"),
            (.unauthorized, "sign-in"),
            (.notFound(MediaID(.album, "al/9")), "album al/9"),
            (.unsupported(.radio), "does not support"),
            (.unknownOutput(OutputDevice.ID(rawValue: "kitchen")), "output"),
            (.backend("Boom"), "Boom"),
            (.forbidden("No scope"), "No scope"),
        ]
        for (error, fragment) in cases {
            let text = error.errorDescription ?? ""
            #expect(text.contains(fragment), "\(error): \(text)")
        }
        #expect(QueueEditError.buffered.errorDescription?.contains("buffered") == true)

        let output = OutputDevice.ID(rawValue: "kitchen")
        let empty = RemoteQueueSnapshot.empty(on: output)
        #expect(empty.output == output)
        #expect(empty.items.isEmpty)
        #expect(empty.total == 0)
        #expect(empty.currentIndex == nil)
        #expect(empty.isComplete)
    }

    @Test func radioURLInputParses() {
        #expect(RadioURLInput.parse("") == nil)
        #expect(RadioURLInput.parse("   \n") == nil)
        #expect(RadioURLInput.parse("https://") == nil)
        let fromHost = RadioURLInput.parse("  https://stream.example/live \n")
        #expect(fromHost?.url == "https://stream.example/live")
        #expect(fromHost?.name == "stream.example")
        #expect(RadioURLInput.parse("HTTP://a.example/x", name: "   ")?.name == "a.example")
        let named = RadioURLInput.parse("http://a.example/x", name: "  Mine ")
        #expect(named?.url == "http://a.example/x")
        #expect(named?.name == "Mine")
        #expect(RadioURLInput.parse("ftp://a.example/x") == nil)

        let radio = LibraryRadio(id: MediaID(.radio, "r/1"), name: "KEXP")
        #expect(radio.artwork == nil)
        #expect(radio.isFavorite == nil)
    }
}
