import LibraryBrowser
import MusicBackendKit
import SwiftUI

/// The Library toolbar's Output button (#0064, #0118): a popover with a checkbox per output, so several can play in
/// sync, an "Only" button for the old single pick, then Music Assistant's groups. The first checked is the leader:
/// transport commands go there and the skinned window shows its now-playing.
struct OutputPickerView: View {
    @Environment(PlayerModel.self) private var player
    @State private var isPresented = false

    var body: some View {
        let selection = player.outputSelection
        Button {
            isPresented.toggle()
        } label: {
            Label(selection.label(names: name(of:)), systemImage: selection.members.isEmpty ? "hifispeaker" : "hifispeaker.2")
                .labelStyle(.titleAndIcon)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover.onAppear { refresh() }
        }
        .onAppear { refresh() }
        .accessibilityIdentifier("library.output")
        .help("Output")
    }

    private var popover: some View {
        let picker = player.outputPicker
        return VStack(alignment: .leading, spacing: 6) {
            Text("This Mac").font(.caption).foregroundStyle(.secondary)
            row(OutputDevice.thisMac)
            if !picker.speakers.isEmpty {
                Text("Speakers").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(picker.speakers) { row($0) }
            }
            if !picker.groups.isEmpty {
                Text("Groups").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(picker.groups) { groupRow($0) }
            }
            if let hint = picker.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .padding(12)
        .frame(minWidth: 240, alignment: .leading)
    }

    private func name(of id: OutputDevice.ID) -> String { Self.name(of: id, devices: player.outputPicker.devices) }

    /// The device's name; This Mac's, or "Speaker" for an id the picker no longer lists.
    static func name(of id: OutputDevice.ID, devices: [OutputDevice]) -> String {
        devices.first { $0.id == id }?.name
            ?? (id == OutputDevice.thisMacID ? OutputDevice.thisMac.name : "Speaker")
    }

    /// A checkbox row's state (#0215).
    struct RowState: Equatable {
        var isChecked: Bool
        /// The checkbox is off: unavailable, or not groupable with the selection.
        var isDisabled: Bool
        /// The "leader" caption shows.
        var showsLeader: Bool
        /// Only is off.
        var onlyDisabled: Bool
    }

    static func rowState(_ device: OutputDevice, selection: OutputSelection) -> RowState {
        let isChecked = selection.all.contains(device.id)
        let canCheck = isChecked || OutputSelection.canAdd(device, to: selection)
        return RowState(
            isChecked: isChecked, isDisabled: !device.isAvailable || !canCheck,
            showsLeader: device.id == selection.leader && !selection.members.isEmpty, onlyDisabled: !device.isAvailable)
    }

    /// A group row shows a checkmark when it leads the selection.
    static func groupIsChecked(_ device: OutputDevice, selection: OutputSelection) -> Bool {
        device.id == selection.leader
    }

    private func row(_ device: OutputDevice) -> some View {
        let selection = player.outputSelection
        let state = Self.rowState(device, selection: selection)
        let isChecked = state.isChecked
        return HStack {
            Toggle(
                isOn: Binding(get: { isChecked }, set: { _ in player.toggleOutput(device.id) })
            ) {
                Text(device.name)
                if state.showsLeader {
                    Text("leader").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(state.isDisabled)
            Spacer(minLength: 12)
            Button("Only") { player.selectOnlyOutput(device.id) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .disabled(state.onlyDisabled)
        }
        .help(device.id == selection.leader ? "Transport and now-playing follow this output" : "")
        .accessibilityIdentifier("library.output.\(device.id.rawValue)")
    }

    private func groupRow(_ device: OutputDevice) -> some View {
        Button {
            player.selectOnlyOutput(device.id)
        } label: {
            HStack {
                Image(systemName: "checkmark").opacity(Self.groupIsChecked(device, selection: player.outputSelection) ? 1 : 0)
                Text(device.name)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!device.isAvailable)
        .accessibilityIdentifier("library.output.\(device.id.rawValue)")
    }

    private func refresh() {
        Task { await player.refreshOutputs() }
    }
}
