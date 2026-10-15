import Foundation
import Testing
@testable import MusicAssistantKit

func makeServer(
    _ url: String = "http://ma.local:8095", id: String? = fixtureServerID, name: String = "Home", uuid: UUID = UUID()
) -> MusicAssistantServerConfiguration {
    MusicAssistantServerConfiguration(
        id: uuid, name: name, address: MusicAssistantServerAddress(baseURL: URL(string: url)!, serverID: id))
}

struct ServerStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ma-store-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func roundTripsInListOrder() {
        withDefaults { defaults in
            let store = MusicAssistantServerStore(defaults: defaults)
            var a = makeServer("http://a.local:8095", name: "A")
            a.networks = ["Home Wi-Fi"]
            let b = makeServer("https://music.example.test", id: nil, name: "B")
            store.save([b, a])
            #expect(store.load() == [b, a])
        }
    }

    @Test func missingOrCorruptLoadsEmptyAndIsNotRewritten() {
        withDefaults { defaults in
            let store = MusicAssistantServerStore(defaults: defaults)
            #expect(store.load().isEmpty)
            #expect(defaults.data(forKey: MusicAssistantServerStore.defaultsKey) == nil)
            let junk = Data("not json".utf8)
            defaults.set(junk, forKey: MusicAssistantServerStore.defaultsKey)
            #expect(store.load().isEmpty)
            #expect(!MusicAssistantServerStore.hasVerifiedServer(defaults: defaults))
            #expect(defaults.data(forKey: MusicAssistantServerStore.defaultsKey) == junk)
        }
    }

    @Test func encodedKeysAreExactlyTheDocumentedSet() throws {
        let data = try JSONEncoder().encode([makeServer()])
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        let server = try #require(top)
        #expect(Set(server.keys) == ["id", "name", "address", "networks"])
        let address = try #require(server["address"] as? [String: Any])
        #expect(Set(address.keys) == ["baseURL", "serverID"])
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("token"))
    }

    @Test func decodesWithoutNetworks() throws {
        let json = """
            [{"id":"6F2D5B0E-3A55-4B53-8B2E-0F4D2E2D7C11","name":"Old","address":{"baseURL":"http://ma.local:8095"}}]
            """
        let servers = try JSONDecoder().decode([MusicAssistantServerConfiguration].self, from: Data(json.utf8))
        #expect(servers.count == 1)
        #expect(servers[0].networks == [])
        #expect(!servers[0].isVerified)
    }

    @Test func hasVerifiedServerReadsDefaultsOnly() {
        withDefaults { defaults in
            #expect(!MusicAssistantServerStore.hasVerifiedServer(defaults: defaults))
            let store = MusicAssistantServerStore(defaults: defaults)
            store.save([makeServer(id: nil)])
            #expect(!MusicAssistantServerStore.hasVerifiedServer(defaults: defaults))
            store.save([makeServer(id: nil), makeServer()])
            #expect(MusicAssistantServerStore.hasVerifiedServer(defaults: defaults))
        }
    }

    @Test func firstVerifiedSkipsUntestedServers() {
        let untested = makeServer(id: nil, name: "Untested")
        let first = makeServer(name: "First")
        let second = makeServer(name: "Second")
        #expect(MusicAssistantActiveServer.firstVerified(in: [untested, first, second]) == first)
        #expect(MusicAssistantActiveServer.firstVerified(in: [untested]) == nil)
        #expect(MusicAssistantActiveServer.firstVerified(in: []) == nil)
    }
}

struct ActiveServerTests {
    @Test func setReportsIdentityChangesOnly() {
        let box = MusicAssistantActiveServer()
        var server = makeServer()
        #expect(box.set(server) == true)
        #expect(box.set(server) == false)
        var renamed = server
        renamed.name = "Renamed"
        #expect(box.set(renamed) == false)
        #expect(box.current?.name == "Renamed")
        var moved = server
        moved.address.baseURL = URL(string: "http://other.local:8095")!
        #expect(box.set(moved) == true)
        server.address.serverID = "another-id"
        #expect(box.set(server) == true)
        #expect(box.set(nil) == true)
        #expect(box.set(nil) == false)
    }

    @Test func readableFromAnotherIsolation() async {
        let server = makeServer()
        let box = MusicAssistantActiveServer(server)
        let read = await Task.detached { box.current?.id }.value
        #expect(read == server.id)
        _ = await Task.detached { box.set(nil) }.value
        #expect(box.current == nil)
    }
}
