import Foundation
import Testing
@testable import SendspinPlayback

struct SendspinAutoConnectTests {
    let a = URL(string: "http://ma-a.test:8095")!
    let b = URL(string: "http://ma-b.test:8095")!

    @Test func startsWhenEnabledAndConnected() {
        #expect(SendspinAutoConnect.decide(enabled: true, endpointURL: a, runningURL: nil) == .start)
    }

    @Test func restartsWhenTheServerChanges() {
        #expect(SendspinAutoConnect.decide(enabled: true, endpointURL: b, runningURL: a) == .restart)
    }

    @Test func stopsWhenDisabledOrDisconnected() {
        #expect(SendspinAutoConnect.decide(enabled: false, endpointURL: a, runningURL: a) == .stop)
        #expect(SendspinAutoConnect.decide(enabled: true, endpointURL: nil, runningURL: a) == .stop)
    }

    @Test func doesNothingWhenUnchanged() {
        #expect(SendspinAutoConnect.decide(enabled: true, endpointURL: a, runningURL: a) == .none)
        #expect(SendspinAutoConnect.decide(enabled: false, endpointURL: a, runningURL: nil) == .none)
        #expect(SendspinAutoConnect.decide(enabled: true, endpointURL: nil, runningURL: nil) == .none)
        #expect(SendspinAutoConnect.decide(enabled: false, endpointURL: nil, runningURL: nil) == .none)
    }
}
