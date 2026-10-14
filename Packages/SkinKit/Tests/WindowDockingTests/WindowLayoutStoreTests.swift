import Foundation
import Testing
@testable import WindowDocking

private func withDefaults(_ body: (UserDefaults) -> Void) {
    let suite = "WindowLayoutStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(defaults)
}

struct WindowLayoutStoreTests {
    @Test func layoutRoundTrips() {
        withDefaults { defaults in
            let store = WindowLayoutStore(defaults: defaults)
            let layout = WindowLayout(windows: [
                .main: .init(left: 445, top: -1), .playlist: .init(left: 445, top: 463.5),
            ])
            store.save(layout)
            #expect(store.load() == layout)
        }
    }

    @Test func missingOrCorruptLayoutLoadsNil() {
        withDefaults { defaults in
            let store = WindowLayoutStore(defaults: defaults)
            #expect(store.load() == nil)
            defaults.set(Data("not json".utf8), forKey: WindowLayoutStore.defaultKey)
            #expect(store.load() == nil)
        }
    }

    @Test func unknownWindowKindsAreDropped() {
        withDefaults { defaults in
            let json = #"{"version":1,"windows":{"main":{"left":1,"top":2},"milkdrop":{"left":3,"top":4}}}"#
            defaults.set(Data(json.utf8), forKey: WindowLayoutStore.defaultKey)
            #expect(WindowLayoutStore(defaults: defaults).load()?.windows == [.main: .init(left: 1, top: 2)])
        }
    }

    @Test func newerVersionLoadsNil() {
        withDefaults { defaults in
            defaults.set(Data(#"{"version":2,"windows":{}}"#.utf8), forKey: WindowLayoutStore.defaultKey)
            #expect(WindowLayoutStore(defaults: defaults).load() == nil)
        }
    }
}
