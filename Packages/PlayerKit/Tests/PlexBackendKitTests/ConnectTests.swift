import Foundation
import MusicBackendKit
import PlexKit
import PlexKitStub
import Testing

@MainActor
struct PlexBackendConnectTests {
    @Test func connectPicksTheOnlyMusicSection() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        try f.register([try .json(.artistsPage, path: "/library/sections/5/all", query: ["type": "8"])])
        try await f.backend.connect()
        #expect(await f.backend.isConnected)
        #expect(await f.backend.machineIdentifier == testMachine)
        _ = try await f.backend.artists(page: .first)
        let request = try #require(f.libraryRequests.first)
        #expect(request.url.path == "/library/sections/5/all")
        #expect(queryValue(request, "type") == "8")
    }

    @Test func connectWithoutSettingsThrowsNotConfiguredAndSendsNothing() async throws {
        let f = try BackendFixture(settings: nil); defer { f.cleanup() }
        do {
            try await f.backend.connect()
            Issue.record("connect should have thrown")
        } catch let error as MusicBackendError {
            guard case .notConfigured(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("Settings"))
        }
        #expect(f.handle.recorded.isEmpty)
        #expect(await !f.backend.isConnected)
    }

    @Test func connectMapsUnauthorized() async throws {
        let f = try BackendFixture()
        defer { f.cleanup() }
        f.handle.register([
            try .json(.identity, path: "/identity"),
            .init(path: "/library/sections", status: 401, headers: ["Content-Type": "text/html"], body: Data("<html/>".utf8)),
        ])
        await #expect(throws: MusicBackendError.unauthorized) { try await f.backend.connect() }
    }

    @Test func connectMapsTransportFailuresToUnreachable() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        f.handle.register([.init(path: "/identity", error: URLError(.cannotConnectToHost))])
        do {
            try await f.backend.connect()
            Issue.record("connect should have thrown")
        } catch let error as MusicBackendError {
            guard case .unreachable(let message) = error else { Issue.record("wrong error \(error)"); return }
            #expect(message.hasPrefix("Can't reach the server."))
        }
    }

    @Test func connectHonoursTheSavedSection() async throws {
        let known = try BackendFixture(settings: SettingsBox.standard(sectionKey: "5")); defer { known.cleanup() }
        try await known.backend.connect()
        #expect(await known.backend.isConnected)
        let unknown = try BackendFixture(settings: SettingsBox.standard(sectionKey: "9")); defer { unknown.cleanup() }
        try await unknown.backend.connect()
        #expect(await unknown.backend.isConnected)
    }

    @Test func connectCanBeRepeated() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        try await f.backend.connect()
        #expect(await f.backend.isConnected)
        f.settings.value = nil
        await #expect(throws: MusicBackendError.self) { try await f.backend.connect() }
        #expect(await !f.backend.isConnected)
    }

    @Test func libraryCallsBeforeConnectThrowNotConnected() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        await #expect(throws: MusicBackendError.notConnected) { _ = try await f.backend.artists(page: .first) }
        await #expect(throws: MusicBackendError.notConnected) { _ = try await f.backend.albums(of: nil, page: .first) }
        await #expect(throws: MusicBackendError.notConnected) { _ = try await f.backend.tracks(of: MediaID(.album, "1")) }
        await #expect(throws: MusicBackendError.notConnected) { _ = try await f.backend.search("x", limit: 5) }
        #expect(f.handle.recorded.isEmpty)
    }

    @Test func disconnectForgetsTheConnection() async throws {
        let f = try BackendFixture(); defer { f.cleanup() }
        try await f.backend.connect()
        await f.backend.disconnect()
        #expect(await !f.backend.isConnected)
        #expect(await f.backend.machineIdentifier == nil)
        await #expect(throws: MusicBackendError.notConnected) { _ = try await f.backend.artists(page: .first) }
    }
}
