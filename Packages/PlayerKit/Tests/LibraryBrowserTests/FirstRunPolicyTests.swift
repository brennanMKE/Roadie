import Testing
@testable import LibraryBrowser

struct FirstRunPolicyTests {
    @Test func freshInstallShowsWelcome() {
        #expect(FirstRunPolicy.decide(FirstRunState()) == .welcome)
    }

    @Test func existingSettingsMarkCompletedWithoutWelcome() {
        #expect(FirstRunPolicy.decide(FirstRunState(hasSkinsFolder: true)) == .markCompleted)
        #expect(FirstRunPolicy.decide(FirstRunState(hasLastSkin: true)) == .markCompleted)
        #expect(FirstRunPolicy.decide(FirstRunState(hasMusicFolder: true)) == .markCompleted)
        #expect(FirstRunPolicy.decide(FirstRunState(hasVerifiedServer: true)) == .markCompleted)
    }

    @Test func completedVersionSkips() {
        #expect(FirstRunPolicy.decide(FirstRunState(completedVersion: 1)) == .skip)
        let all = FirstRunState(
            completedVersion: 1, hasSkinsFolder: true, hasLastSkin: true, hasMusicFolder: true, hasVerifiedServer: true)
        #expect(FirstRunPolicy.decide(all) == .skip)
    }
}
