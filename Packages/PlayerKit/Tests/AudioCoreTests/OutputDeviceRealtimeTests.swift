import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import AudioCore

/// #0048, real-time half. Opt-in like the other real-time suites (`AUDIOCORE_REALTIME=1`, the muted guest
/// device). Nothing here switches a device: the only CoreAudio writes bind the engine to the device it is
/// already on.
@MainActor
@Suite(.serialized) struct OutputDeviceRealtimeTests {
    @Test(.enabled(if: RealtimeAudio.isAvailable))
    func systemProviderReadsWithoutSwitching() async throws {
        let system = SystemOutputDeviceProvider()
        let device = try #require(system.defaultOutputDevice())
        let info = try #require(system.describe(device))
        #expect(!info.name.isEmpty)
        #expect(info.nominalSampleRate > 0)

        // Listener install/remove round trip; the default does not move, so no element arrives.
        let listener = Task { () -> Int in
            var count = 0
            for await _ in system.defaultOutputDeviceChanges() { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        listener.cancel()
        _ = await listener.value

        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "f.wav")
        try MixedFormatSupport.writeSine(to: url, rate: 44100, channels: 2, seconds: 0.5, amplitude: 0.05)
        let player = Player()
        player.enqueue([try Track.file(at: url)])
        player.volume = 0 // silent
        player.play()
        #expect(await MixedFormatSupport.waitUntil { player.state == .playing })
        let graph = player.ensureGraph()
        let unit = graph.engine.outputNode.audioUnit
        var description = AudioComponentDescription()
        if let unit {
            AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description)
        }
        let bound = system.boundDevice(of: graph.engine.outputNode)
        print("[#0048] default device \(device) \(info.name) transport \(info.transport) nominal \(info.nominalSampleRate)")
        print("[#0048] output node bound to \(bound.map(String.init) ?? "nil"), unit subtype \(description.componentSubType) (HAL = 1634230636 'ahal'; default-output = 1684366880 'def '), processing rate \(graph.processingSampleRate ?? 0)")
        player.stop()
    }

    @Test(.enabled(if: RealtimeAudio.isAvailable))
    func rebindingToCurrentDeviceKeepsPlaying() async throws {
        let system = SystemOutputDeviceProvider()
        let current = try #require(system.defaultOutputDevice())
        let provider = ManualOutputDeviceProvider(current: current, forwardBindsTo: system)
        let dir = try MixedFormatSupport.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var tracks: [Track] = []
        for i in 0..<2 {
            let url = dir.appending(path: "f\(i).wav")
            try MixedFormatSupport.writeSine(to: url, rate: 44100, channels: 2, seconds: 0.5, amplitude: 0.05)
            tracks.append(try Track.file(at: url))
        }
        let player = Player(outputDevices: provider)
        player.recordsDiagnostics = true
        player.enqueue(tracks)
        player.volume = 0 // silent
        // The output unit accepts setDeviceID on this macOS (the engine is stopped, and this is the device it
        // is already bound to, so nothing switches). The player's own bind skips an already-bound device.
        let node = player.ensureGraph().engine.outputNode
        try node.auAudioUnit.setDeviceID(current)
        player.play()
        #expect(await MixedFormatSupport.waitUntil { player.state == .playing })
        let schedulesBefore = player.scheduleDiagnostics.count

        provider.send(current)   // the device the engine is already on: nothing switches
        #expect(await MixedFormatSupport.waitUntil { player.scheduleDiagnostics.count > schedulesBefore })
        #expect(player.state == .playing || player.state == .stopped)
        #expect(provider.binds.isEmpty)   // already bound to it: no rebind
        #expect(player.errorMessage == nil)
        #expect(await MixedFormatSupport.waitUntil(timeout: 300) { player.state == .stopped })
        #expect(player.errorMessage == nil)
        #expect(player.completionDiagnostics.last == .reachedEnd)
    }
}
