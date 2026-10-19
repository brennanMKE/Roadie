import AudioCore
import Foundation
import Testing

struct TrackInfoTests {
    private func value(_ info: TrackInfo, _ label: String) -> String? {
        info.rows.first { $0.label == label }?.value
    }

    @Test func rowsForALocalFileTrack() {
        let track = Track(
            title: "Song", artist: "Band", album: "Record", duration: 245, bitrate: 900, sampleRate: 44100, channels: 2,
            source: .file(URL(fileURLWithPath: "/a/b.flac")))
        let info = TrackInfo(track: track, format: nil)
        #expect(info.rows.map(\.label) == [
            "Title", "Artist", "Album", "Duration", "Format", "Bitrate", "Sample rate", "Channels",
        ])
        #expect(info.rows.map(\.value) == ["Song", "Band", "Record", "4:05", "FLAC", "900 kbps", "44.1 kHz", "Stereo"])
    }

    @Test func playbackFormatOverridesTrackRateAndChannels() {
        let track = Track(
            title: "Song", artist: "Band", duration: 10, sampleRate: 44100, channels: 2,
            source: .file(URL(fileURLWithPath: "/a/b.mp3")))
        let info = TrackInfo(track: track, format: PlaybackFormat(sampleRate: 48000, channels: 1))
        #expect(value(info, "Sample rate") == "48 kHz")
        #expect(value(info, "Channels") == "Mono")
    }

    @Test func missingValuesShowADash() {
        let track = Track(title: "Song", artist: "Band", duration: 10, source: .plex(partKey: "p", cacheKey: "c"))
        let info = TrackInfo(track: track, format: nil)
        for label in ["Album", "Format", "Bitrate", "Sample rate"] {
            #expect(value(info, label) == "—")
        }
    }

    @Test func durationOverAnHourUsesHours() {
        let info = TrackInfo(title: "Long", artist: "Band", duration: 3725)
        #expect(value(info, "Duration") == "1:02:05")
    }
}
