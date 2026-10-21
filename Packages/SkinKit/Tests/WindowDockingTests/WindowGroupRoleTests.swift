import Testing
@testable import WindowDocking

/// #0120: with Stage Manager showing one window at a time, the equalizer and playlist must stay on stage with main.
struct WindowGroupRoleTests {
    @Test func mainWindowIsThePrimaryWindow() {
        #expect(WindowKind.main.windowGroupRole == .primary)
    }

    @Test func equalizerAndPlaylistAreAuxiliaryWindows() {
        #expect(WindowKind.equalizer.windowGroupRole == .auxiliary)
        #expect(WindowKind.playlist.windowGroupRole == .auxiliary)
    }

    @Test func exactlyOnePrimaryWindow() {
        #expect(WindowKind.allCases.filter { $0.windowGroupRole == .primary } == [.main])
    }

    @Test func equalizerAndPlaylistAreChildWindowsOfMain() {
        #expect(WindowKind.main.parentWindow == nil)
        #expect(WindowKind.equalizer.parentWindow == .main)
        #expect(WindowKind.playlist.parentWindow == .main)
    }
}
