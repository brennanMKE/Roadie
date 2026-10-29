import VisualizationKit

/// The preset list (#0240, design §2.5 L): open, close and load. While it's open auto-advance is suspended and keys go
/// to the list (`perform` passes only Esc and ⌥Return); the song overlay (#0238) holds itself up while `isListOpen`.
extension VisualizationModel {
    /// Setting false closes the list, true opens it.
    var isListOpen: Bool {
        get { presetList != nil }
        set { if newValue { openList() } else { closeList() } }
    }

    /// Reads the presets once, selecting the one showing.
    func openList() {
        guard presetList == nil else { return }
        let usable = Set(navigator.usable.map(\.id))
        let failed = Set(navigator.presets.map(\.id).filter { !usable.contains($0) })
        presetList = PresetListModel(presets: navigator.presets, currentID: currentPreset?.id, failedIDs: failed)
        setSuspended(.list, true)
        setOverlayHold(.browser, true)
    }

    func closeList() {
        guard presetList != nil else { return }
        presetList = nil
        setSuspended(.list, false)
        setOverlayHold(.browser, false)
    }

    /// Return or a double-click: loads the selected preset with the key blend and closes. A failed preset can't be
    /// loaded; the list stays open.
    func loadListSelection() {
        guard let row = presetList?.selectedRow, !row.isFailed else { return }
        closeList()
        if row.preset.id != currentPreset?.id { load(row.preset, transition: VisualizationSettings.keyBlend) }
    }
}
