import AppKit
import SwiftUI
import VisualizationKit

/// Settings › Visualization (#0241, design docs/design/visualization.md §6): preset changes, the presets folder, the
/// full-screen overlay and opening on play. Each change is saved and applied to the running window.
struct VisualizationSettingsView: View {
    @Environment(VisualizationModel.self) private var vis

    /// The idle picker's choices; 0 is Never.
    private static let idleChoices: [TimeInterval] = [2, 3, 5, 10, 0]

    var body: some View {
        Form {
            Section("Presets") {
                Toggle("Change presets automatically", isOn: binding(\.autoAdvance))
                    .accessibilityIdentifier("vis.settings.autoAdvance")
                if vis.accessibilityState.reduceMotion {
                    // Reduce Motion pauses automatic changes unless the user asks for them (#0242, design §7).
                    Text("Paused while Reduce Motion is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .skinDisplay(
                            "vis.settings.reduceMotionNote", label: "Paused while Reduce Motion is on.",
                            value: "Paused while Reduce Motion is on.")
                    Toggle("Change them anyway", isOn: binding(\.changeWithReduceMotion))
                        .disabled(!vis.settings.autoAdvance)
                        .accessibilityIdentifier("vis.settings.changeAnyway")
                }
                LabeledContent("Every") {
                    HStack {
                        TextField("Seconds", value: binding(\.autoAdvanceSeconds), format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("vis.settings.interval")
                        Stepper(
                            "Seconds", value: binding(\.autoAdvanceSeconds), in: VisualizationSettings.autoAdvanceRange,
                            step: 1
                        )
                        .labelsHidden()
                        Text("seconds")
                    }
                }
                .disabled(!vis.settings.autoAdvance)
                Toggle("Vary the time", isOn: binding(\.autoAdvanceVaries))
                    .disabled(!vis.settings.autoAdvance)
                    .accessibilityIdentifier("vis.settings.vary")
                LabeledContent("Blend time") {
                    HStack {
                        Slider(value: binding(\.blendSeconds), in: VisualizationSettings.blendRange, step: 0.1)
                            .accessibilityIdentifier("vis.settings.blend")
                        Text(String(format: "%.1f s", vis.settings.blendSeconds))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Order", selection: binding(\.order)) {
                    Text("Random").tag(PresetNavigator.Order.random)
                    Text("In order").tag(PresetNavigator.Order.sequential)
                }
                .accessibilityIdentifier("vis.settings.order")
            }

            if vis.showsPresetsFolder {
                Section {
                    LabeledContent("Folder") {
                        Text(vis.settings.presetsFolder ?? "None")
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(vis.settings.presetsFolder == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("vis.settings.folder")
                    }
                    HStack {
                        Button("Choose\u{2026}") { chooseFolder() }
                            .accessibilityIdentifier("vis.settings.folderChoose")
                        Button("Clear") { vis.updateSettings { $0.presetsFolder = nil } }
                            .disabled(vis.settings.presetsFolder == nil)
                            .accessibilityIdentifier("vis.settings.folderClear")
                        Button("Show in Finder") { showInFinder() }
                            .disabled(vis.folderStatus == .none || vis.folderStatus == .notFound)
                        Spacer()
                        if let status = folderStatusText {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("vis.settings.folderCount")
                        }
                    }
                } header: {
                    Text("Your Presets Folder")
                } footer: {
                    Text("MilkDrop presets (.milk) in this folder and its subfolders join the list after the classics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Overlay") {
                Picker("Hide the overlay and pointer after", selection: binding(\.overlayIdleSeconds)) {
                    ForEach(Self.idleChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .accessibilityIdentifier("vis.settings.idle")
                Toggle("Show the song title when the track changes", isOn: binding(\.songTitleOnTrackChange))
                    .accessibilityIdentifier("vis.settings.songTitle")
            }

            Section("Window") {
                Toggle("Open the visualization when playback starts", isOn: binding(\.openOnPlay))
                    .accessibilityIdentifier("vis.settings.openOnPlay")
            }
        }
        .formStyle(.grouped)
    }

    private var folderStatusText: String? {
        switch vis.folderStatus {
        case .none: nil
        case .scanning: "Looking for presets\u{2026}"
        case .notFound: "Folder not found"
        case .found(let count): count == 1 ? "1 preset found" : "\(count) presets found"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VisualizationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { vis.settings[keyPath: keyPath] },
            set: { value in vis.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func chooseFolder() {
        if let standIn = vis.presetsFolderStandIn {
            vis.updateSettings { $0.presetsFolder = standIn }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of MilkDrop presets"
        if let folder = vis.settings.presetsFolder { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vis.updateSettings { $0.presetsFolder = url.path }
    }

    private func showInFinder() {
        guard let folder = vis.settings.presetsFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder, isDirectory: true)])
    }
}
