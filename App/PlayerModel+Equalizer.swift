import AppKit
import AudioCore
import Foundation
import MusicBackendKit
import SkinKit
import UniformTypeIdentifiers

/// The equalizer window's side of the model. EQ values do not go through `TransportCommand`: the EQ belongs to this
/// Mac's audio graph, a band drag needs the graph and the slider to follow the pointer synchronously, and
/// `Player.eq`'s setter pushes to the live `AVAudioUnitEQ` at once (no stop, no reconnect, so no glitch). With a
/// remote output selected the window still edits and persists `player.eq`; nothing audible changes until the output
/// is This Mac again.
extension PlayerModel {
    var eq: EQState { player.eq }

    /// A band drag: snap near the middle like Winamp, store dB, show "EQ: 60HZ +3.4 DB" in the main window's marquee.
    func setEQBand(_ index: Int, value: Double) {
        guard (0..<EQState.bandCount).contains(index) else { return }
        let gain = EQLayout.gain(forValue: EQLayout.snapped(value))
        player.eq[band: index] = gain
        persistEQ()
        holdSlider(.equalizer(band: index), marquee: MarqueeText.equalizer(bandHz: Int(EQBands.frequencies[index]), gain: gain))
    }

    func setEQPreamp(value: Double) {
        let gain = EQLayout.gain(forValue: EQLayout.snapped(value))
        player.eq.preamp = gain
        persistEQ()
        holdSlider(.equalizer(band: nil), marquee: MarqueeText.equalizer(bandHz: nil, gain: gain))
    }

    /// Drag release: the values already reached the engine, so this only clears the marquee text.
    func endEQDrag() { endSliderDrag() }

    /// The +12 / 0 / -12 dB labels set the ten bands and leave the preamp (Webamp `_setEqTo`).
    func setAllEQBands(value: Double) {
        player.eq.gains = Array(repeating: EQLayout.gain(forValue: value), count: EQState.bandCount)
        persistEQ()
    }

    func toggleEQEnabled() {
        player.eq.isEnabled.toggle()
        persistEQ()
    }

    /// Sets the preamp and bands; keeps ON as it is.
    func applyEQPreset(_ preset: EQPreset) {
        player.eq = player.eq.applying(preset)
        persistEQ()
    }

    private func persistEQ() {
        guard let data = try? JSONEncoder().encode(player.eq) else { return }
        defaults.set(data, forKey: Self.equalizerKey)
    }

    // MARK: Preset files

    private static var presetFileTypes: [UTType] {
        ["eqf", "q1"].compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
    }

    /// Webamp's "From EQF…": the first preset in the chosen file.
    func loadEQF() {
        if intercepted(.loadEQF) { return }
        if let url = panelStandIn(.loadEQF)?.first {
            applyEQF(at: url)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.presetFileTypes
        panel.message = "Choose an equalizer preset file"
        panel.prompt = "Load"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            applyEQF(at: url)
        }
    }

    private func applyEQF(at url: URL) {
        do {
            let presets = try EQFFile.parse(try Data(contentsOf: url))
            guard let first = presets.first else {
                post(StatusNotice(text: "No preset in \(url.lastPathComponent)"))
                return
            }
            applyEQPreset(first)
        } catch {
            post(StatusNotice(text: "Could not read \(url.lastPathComponent)", detail: String(describing: error)))
        }
    }

    /// Webamp's "Save": one preset named "Entry1" with the current bands and preamp, default file name `entry.eqf`.
    func saveEQF() {
        if intercepted(.saveEQF) { return }
        if let url = panelStandIn(.saveTo)?.first {
            writeEQF(player.eq, to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.presetFileTypes.first.map { [$0] } ?? []
        panel.nameFieldStringValue = "entry.eqf"
        panel.prompt = "Save"
        let current = player.eq
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            writeEQF(current, to: url)
        }
    }

    private func writeEQF(_ eq: EQState, to url: URL) {
        let data = EQFFile.serialize([EQPreset(name: "Entry1", preamp: eq.preamp, gains: eq.gains)])
        do { try data.write(to: url) } catch {
            post(StatusNotice(text: "Could not save \(url.lastPathComponent)", detail: error.localizedDescription))
        }
    }
}
