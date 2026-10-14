import AudioCore
import Foundation
import LocalPlayback
import MusicBackendKit
import PlexKit
import PlexKitStub
import Testing
import TrackCache
import os
@testable import PlexBackendKit

let testSecret = "tok-UNIT-TEST-SECRET-0062"
let testIdentifier = "11111111-2222-3333-4444-555555555555"
let testMachine = "0123456789abcdef0123456789abcdef01234567"
let testPartPath = "/library/parts/5010/1791856627/file.m4a"
let testPartSize = 7_147_054
let testBase = "http://stub.local:32400"

func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlexBackendKitTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until `condition` holds (up to `timeout` seconds). No fixed sleeps in the happy path.
@MainActor
func waitFor(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Reads every file under `dir` as bytes and searches for the UTF-8 of `text`.
func directoryContains(_ dir: URL, _ text: String) -> Bool {
    let needle = Data(text.utf8)
    guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let data = try? Data(contentsOf: url) else { continue }
        if data.range(of: needle) != nil { return true }
    }
    return false
}

func header(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
    request.headers.first { $0.key.lowercased() == name.lowercased() }?.value
}

func queryValue(_ request: StubURLProtocol.RecordedRequest, _ name: String) -> String? {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// Settings that tests can change between calls.
final class SettingsBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<PlexBackendSettings?>(initialState: nil)

    init(_ value: PlexBackendSettings?) { lock.withLock { $0 = value } }

    var value: PlexBackendSettings? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    static func standard(sectionKey: String? = nil) -> PlexBackendSettings {
        PlexBackendSettings(
            selection: PlexServerSelection(address: testBase, machineIdentifier: nil, librarySectionKey: sectionKey),
            token: PlexToken(testSecret))
    }
}

/// Fixture album tracks served as a one-page listing plus a part body of the right size.
@MainActor
struct BackendFixture {
    let dir = makeTempDir()
    let handle = StubURLProtocol.handle()
    let settings: SettingsBox
    let cache: TrackCache
    let player: Player
    let output: LocalPlayerOutput
    let backend: PlexBackend

    init(settings: PlexBackendSettings? = SettingsBox.standard(), connectRoutes: Bool = true) throws {
        let box = SettingsBox(settings)
        self.settings = box
        let client = PlexClient(
            baseURL: URL(string: testBase)!, token: PlexToken(testSecret), clientIdentifier: testIdentifier,
            session: handle.session)
        let downloader = PlexPartDownloader(clientProvider: { client }, session: handle.session)
        cache = TrackCache(directory: dir, downloader: downloader)
        player = Player(resolver: PlexTrackResolver(cache: cache, savedMachineIdentifier: { testMachine }))
        output = LocalPlayerOutput(player: player)
        backend = PlexBackend(
            settings: { box.value },
            clientIdentifier: testIdentifier, output: output, session: handle.session)
        if connectRoutes { handle.register(try Self.connectRoutes()) }
    }

    static func connectRoutes() throws -> [StubURLProtocol.Route] {
        [try .json(.identity, path: "/identity"), try .json(.sections, path: "/library/sections")]
    }

    func register(_ extra: [StubURLProtocol.Route]) throws {
        handle.register(extra + (try Self.connectRoutes()))
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    var libraryRequests: [StubURLProtocol.RecordedRequest] {
        handle.recorded.filter { $0.url.path != "/identity" && $0.url.path != "/library/sections" }
    }
}
