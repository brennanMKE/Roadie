import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The Library toolbar's Output menu (#0064): This Mac, Music Assistant's speakers, then its groups. Choosing one
/// sets where transport commands go and whose now-playing the skinned window shows.
struct OutputPickerView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let picker = player.outputPicker
        Menu {
            Section("This Mac") { entry(OutputDevice.thisMac) }
            if !picker.speakers.isEmpty {
                Section("Speakers") { ForEach(picker.speakers) { entry($0) } }
            }
            if !picker.groups.isEmpty {
                Section("Groups") { ForEach(picker.groups) { entry($0) } }
            }
            if let hint = picker.hint {
                Text(hint)
            }
        } label: {
            Label(selectedName, systemImage: "hifispeaker")
                .labelStyle(.titleAndIcon)
        }
        .onAppear { refresh() }
        .accessibilityIdentifier("library.output")
        .help("Output")
    }

    private var selectedName: String {
        player.outputPicker.devices.first { $0.id == player.selectedOutput }?.name
            ?? (player.selectedOutput == OutputDevice.thisMacID ? OutputDevice.thisMac.name : "Speaker")
    }

    private func entry(_ device: OutputDevice) -> some View {
        Button {
            player.selectOutput(device.id)
        } label: {
            if device.id == player.selectedOutput {
                Label(device.name, systemImage: "checkmark")
            } else {
                Text(device.name)
            }
        }
        .disabled(!device.isAvailable)
        .onAppear { if device.id == OutputDevice.thisMacID { refresh() } }
    }

    private func refresh() {
        Task { await player.refreshOutputs() }
    }
}
