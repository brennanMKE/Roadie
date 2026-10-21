import Foundation
import MusicAssistantKitStub
import MusicBackendKit
import Testing
@testable import MusicAssistantKit

/// Radio (#0147). No radio response is recorded yet (#0133), so these use synthetic rows shaped like MA's `Radio`.
struct RadioTests {
    private static let station: MAJSON = [
        "item_id": "3", "provider": "library", "name": "KEXP", "uri": "library://radio/3",
        "media_type": "radio", "favorite": true,
        "metadata": ["images": [["type": "thumb", "path": "x", "provider": "url", "proxy_id": "img3"]]],
        "provider_mappings": [], "duration": 172800,
    ]

    @Test func radioDecodesLeniently() throws {
        let radio = try Self.station.decode(as: MARadio.self)
        #expect(radio.itemID == "3")
        let mapped = LibraryRadio(ma: radio)
        #expect(mapped.id == MediaID(.radio, "library://radio/3"))
        #expect(mapped.name == "KEXP")
        #expect(mapped.isFavorite == true)
        // A numeric id decodes; a row without a uri is dropped, not fatal.
        let rows: MAJSON = [Self.station, ["item_id": 4, "name": "Bare", "uri": "library://radio/4"], ["name": "No URI"]]
        let list = MARadio.lenientList(rows)
        #expect(list.map(\.itemID) == ["3", "4"])
        #expect(list[1].metadata == nil)
    }

    @Test func radioRequestsEncode() {
        let page = MARequest.libraryItems(.radio, limit: 50, offset: 0)
        #expect(page.command == "music/radios/library_items")
        #expect(MARequest.count(.radio).command == "music/radios/count")
        let favorites = MARequest.favoriteLibraryItems(.radio, limit: 10, offset: 0)
        #expect(favorites.command == "music/radios/library_items")
        #expect(favorites.args["favorite"] == .bool(true))
        let add = MARequest.addRadio(url: "https://stream.example/live", name: "Example")
        #expect(add.command == "builtin/add_radio")
        #expect(MAJSON.object(add.args) == ["url": "https://stream.example/live", "name": "Example"])
    }

    @Test func backendListsAndAddsRadio() async throws {
        let rig = try await connectedBackend(
            script: controlScript {
                $0.override("music/radios/library_items", result: [Self.station])
                $0.override("music/radios/count", result: 1)
                $0.override("builtin/add_radio", result: Self.station)
            })
        #expect(rig.backend.capabilities.contains(.radio))
        let page = try await rig.backend.radios(page: PageRequest(offset: 0, limit: 50))
        #expect(page.items.map(\.name) == ["KEXP"])
        #expect(page.total == 1)
        let added = try await rig.backend.addRadio(url: "https://stream.example/live", name: "Example")
        #expect(added.id == MediaID(.radio, "library://radio/3"))
        let sent = try #require(rig.transport.sentRequests.first { $0.command == "builtin/add_radio" })
        #expect(sent.args["url"] == .string("https://stream.example/live"))
        await rig.backend.disconnect()
    }
}
