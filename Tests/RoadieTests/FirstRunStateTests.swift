import FolderBackendKit
import LibraryBrowser
import MusicAssistantKit
import XCTest

@testable import Roadie

/// `PlayerModel.firstRunState(defaults:)` (#0169) against a throwaway defaults suite (#0193).
@MainActor
final class FirstRunStateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "co.sstools.roadie.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private var state: FirstRunState { PlayerModel.firstRunState(defaults: defaults) }

    func testFreshDefaultsAreAFreshInstall() {
        XCTAssertEqual(
            state,
            FirstRunState(
                completedVersion: 0, hasSkinsFolder: false, hasLastSkin: false, hasMusicFolder: false,
                hasVerifiedServer: false))
    }

    func testSkinsFolderCountsAsConfigured() {
        defaults.set("/tmp/Skins", forKey: SkinLibraryModel.folderKey)
        XCTAssertTrue(state.hasSkinsFolder)
        XCTAssertFalse(state.hasLastSkin)
    }

    func testLastSkinCountsAsConfigured() {
        defaults.set("/tmp/Skins/base.wsz", forKey: PlayerModel.lastSkinKey)
        XCTAssertTrue(state.hasLastSkin)
        XCTAssertFalse(state.hasSkinsFolder)
    }

    func testMusicFolderCountsAsConfigured() {
        defaults.set("/tmp/Music", forKey: FolderBackend.folderDefaultsKey)
        XCTAssertTrue(state.hasMusicFolder)
    }

    func testVerifiedServerCountsAsConfigured() {
        let store = MusicAssistantServerStore(defaults: defaults)
        let url = URL(string: "http://ma.local:8095")!
        let unverified = MusicAssistantServerConfiguration(address: MusicAssistantServerAddress(baseURL: url))
        store.save([unverified])
        XCTAssertFalse(state.hasVerifiedServer)
        let verified = MusicAssistantServerConfiguration(
            address: MusicAssistantServerAddress(baseURL: url, serverID: "server-1"))
        store.save([unverified, verified])
        XCTAssertTrue(state.hasVerifiedServer)
    }

    func testCompletedVersionIsRead() {
        defaults.set(3, forKey: FirstRunPolicy.defaultsKey)
        XCTAssertEqual(state.completedVersion, 3)
    }
}
