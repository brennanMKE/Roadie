import Testing
@testable import SkinKit

struct MediaInfoTextTests {
    @Test func kbpsPadsAndAbbreviates() {
        #expect(MediaInfoText.kbps(nil) == "  0")
        #expect(MediaInfoText.kbps(8) == "  8")
        #expect(MediaInfoText.kbps(96) == " 96")
        #expect(MediaInfoText.kbps(100) == "100")
        #expect(MediaInfoText.kbps(128) == "128")
        #expect(MediaInfoText.kbps(320) == "320")
        #expect(MediaInfoText.kbps(1411) == "14H")
        #expect(MediaInfoText.kbps(12345) == " 1C")
    }

    @Test func khzRoundsAndPads() {
        #expect(MediaInfoText.khz(sampleRate: nil) == " 0")
        #expect(MediaInfoText.khz(sampleRate: 8000) == " 8")
        #expect(MediaInfoText.khz(sampleRate: 11025) == "11")
        #expect(MediaInfoText.khz(sampleRate: 22050) == "22")
        #expect(MediaInfoText.khz(sampleRate: 44100) == "44")
        #expect(MediaInfoText.khz(sampleRate: 48000) == "48")
        #expect(MediaInfoText.khz(sampleRate: 96000) == "96")
        // Webamp's slice(1, 3) quirk, pinned so a change is deliberate.
        #expect(MediaInfoText.khz(sampleRate: 192000) == "92")
    }

    @Test func kbpsIsAlwaysThreeCharacters() {
        #expect((0...20000).allSatisfy { MediaInfoText.kbps($0).count == 3 })
    }

    @Test func khzIsAlwaysTwoCharacters() {
        #expect((0...200_000).allSatisfy { MediaInfoText.khz(sampleRate: Double($0)).count == 2 })
    }
}
