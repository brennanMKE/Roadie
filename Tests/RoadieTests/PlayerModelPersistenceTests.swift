import AudioCore
import Foundation
import XCTest

@testable import Roadie

/// What `PlayerModel` keeps in its defaults and reads back at init (#0211). A second model on the same data directory
/// and defaults suite stands in for a relaunch.
@MainActor
final class PlayerModelPersistenceTests: PlayerModelTestCase {
    private func relaunch(_ configuration: RoadieConfiguration) throws -> PlayerModel {
        makeModel(try testConfiguration(dataDirectory: configuration.dataDirectory, defaults: configuration.defaults))
    }

    func testEqStateRoundTrips() throws {
        let configuration = try testConfiguration()
        let first = makeModel(configuration)
        first.setEQBand(3, value: 0.9)
        first.setEQPreamp(value: 0.2)
        first.toggleEQEnabled()
        first.endEQDrag()
        XCTAssertNotNil(configuration.defaults.data(forKey: PlayerModel.equalizerKey))
        let second = try relaunch(configuration)
        XCTAssertEqual(second.eq, first.eq)
    }

    func testTimeModePersists() throws {
        let configuration = try testConfiguration()
        makeModel(configuration).setTimeMode(.remaining)
        XCTAssertEqual(try relaunch(configuration).timeMode, .remaining)
    }

    func testWindowFlagsPersist() throws {
        let configuration = try testConfiguration()
        let first = makeModel(configuration)
        first.setEQWindowOpen(true)
        first.toggleMainWindowShade()
        first.toggleEQWindowShade()
        first.togglePlaylistWindowShade()
        first.toggleAlwaysOnTop()
        first.toggleDoubleSize()
        let second = try relaunch(configuration)
        XCTAssertTrue(second.isEQWindowOpen)
        XCTAssertTrue(second.isMainWindowShaded)
        XCTAssertTrue(second.isEQWindowShaded)
        XCTAssertTrue(second.isPlaylistWindowShaded)
        XCTAssertTrue(second.isAlwaysOnTop)
        XCTAssertTrue(second.isDoubleSize)
        XCTAssertEqual(second.scale, PlayerModel.baseScale * 2)
    }

    func testLastSkinPathIsLoadedAtInit() async throws {
        let skin = try makeSkin(named: "Generated")
        let configuration = try testConfiguration()
        configuration.defaults.set(skin.path, forKey: PlayerModel.lastSkinKey)
        let model = makeModel(configuration)
        try await waitUntil("the skin loads") { model.skin != nil || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.skin)
        XCTAssertEqual(model.skinName, "Generated")
    }

    func testLoadSkinFailurePostsANotice() async throws {
        let junk = try temporaryDirectory("roadie-junk").appending(path: "Junk.wsz")
        try Data("not a zip".utf8).write(to: junk)
        let model = try makeModel()
        model.loadSkin(from: junk)
        try await waitUntil("the notice") { model.notice != nil }
        XCTAssertEqual(model.notice?.text, StatusNotice.skinFailed("Junk").text)
        XCTAssertNil(model.skin)
        XCTAssertNil(model.defaults.string(forKey: PlayerModel.lastSkinKey))
    }
}
