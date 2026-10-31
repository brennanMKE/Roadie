import Foundation
import Testing
@testable import VisualizationKit

struct PresetCatalogTests {
    @Test func classicsAreFiveInStyleOrder() {
        let classics = PresetCatalog.classics
        #expect(classics.map(\.id) == [
            "classic:spectrum", "classic:oscilloscope", "classic:spectrumAndScope", "classic:mirror", "classic:stereoScope",
        ])
        #expect(classics.map(\.name) == [
            "Classic Spectrum", "Classic Oscilloscope", "Classic Spectrum and Scope", "Classic Mirror", "Classic Stereo Scope",
        ])
        #expect(classics.allSatisfy { $0.source == .builtIn && $0.url == nil })
    }

    @Test func scanFindsMilkFilesRecursively() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VisKit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Pack.milkpreset"), withIntermediateDirectories: true)
        for path in ["a.milk", "Sub/B.MILK", ".hidden.milk", "notes.txt", "Pack.milkpreset/inner.milk"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(path))
        }

        let found = PresetCatalog.scan(folder: root, source: .user).sorted { $0.id < $1.id }

        #expect(found.map(\.id) == ["user:Pack.milkpreset", "user:Sub/B.MILK", "user:a.milk"])
        #expect(found.map(\.name) == ["Pack", "B", "a"])
        #expect(found.allSatisfy { $0.kind == .milk && $0.source == .user && $0.url != nil })
    }

    @Test func scanOfAMissingFolderIsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("VisKit-missing-\(UUID().uuidString)")
        #expect(PresetCatalog.scan(folder: missing, source: .user).isEmpty)
    }

    @Test func orderedPutsClassicsFirstThenNaturalNameOrder() {
        func milk(_ name: String, _ source: VisualizationPreset.Source) -> VisualizationPreset {
            .milk(url: URL(fileURLWithPath: "/tmp/\(name).milk"), relativePath: "\(name).milk", source: source)
        }
        let files = [milk("Preset 10", .user), milk("Same", .user), milk("preset 2", .bundled),
                     milk("Äther", .user), milk("Same", .bundled)]
        let input = [files[0], PresetCatalog.classics[3], files[1], PresetCatalog.classics[0], files[2],
                     PresetCatalog.classics[4], files[3], PresetCatalog.classics[1], files[4], PresetCatalog.classics[2]]

        let ordered = PresetCatalog.ordered(input)

        #expect(Array(ordered.prefix(5)) == PresetCatalog.classics)
        #expect(ordered.dropFirst(5).map(\.id) == [
            "user:Äther.milk", "bundled:preset 2.milk", "user:Preset 10.milk", "bundled:Same.milk", "user:Same.milk",
        ])
    }

    private func bundleFolder(gallery: String?) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VisKit-bundled-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["spike-tunnel.milk", "zoom.milk"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        if let gallery { try Data(gallery.utf8).write(to: root.appendingPathComponent("gallery.json")) }
        return root
    }

    /// #0258: the gallery names the presets it lists; the rest keep their file names.
    @Test func testBundledNamesComeFromTheGallery() throws {
        let root = try bundleFolder(gallery: """
            {"categories": [{"name": "Showcase", "presets": [{"file": "spike-tunnel.milk", "title": "Spike Tunnel", "summary": "s"}]}]}
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let found = PresetCatalog.bundled(in: root).sorted { $0.id < $1.id }
        #expect(found.map(\.id) == ["bundled:spike-tunnel.milk", "bundled:zoom.milk"])
        #expect(found.map(\.name) == ["Spike Tunnel", "zoom"])
        #expect(found.allSatisfy { $0.source == .bundled && $0.kind == .milk })
    }

    @Test func testBundledWithoutAGalleryUsesFileNames() throws {
        for gallery in [nil, "not json"] as [String?] {
            let root = try bundleFolder(gallery: gallery)
            defer { try? FileManager.default.removeItem(at: root) }
            let found = PresetCatalog.bundled(in: root).sorted { $0.id < $1.id }
            #expect(found.map(\.name) == ["spike-tunnel", "zoom"])
            #expect(found.map(\.id) == ["bundled:spike-tunnel.milk", "bundled:zoom.milk"])
        }
    }
}
