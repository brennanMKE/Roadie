import Foundation
import Observation
import VisualizationKit

/// The preset list's state (#0240, design §2.5 L): the presets read once on open, the search text, the filtered rows
/// and the selection. `VisualizationPresetListView` binds it; `VisualizationModel` owns it while the list is open.
@MainActor
@Observable
final class PresetListModel {
    struct Row: Identifiable, Equatable {
        let preset: VisualizationPreset
        let isCurrent: Bool
        let isFailed: Bool
        var id: String { preset.id }

        /// The trailing tag: "Classic", "MilkDrop" (bundled) or "Yours".
        var sourceTag: String {
            switch preset.source {
            case .builtIn: "Classic"
            case .bundled: "MilkDrop"
            case .user: "Yours"
            }
        }

        /// The row's accessibility value.
        var status: String { isFailed ? "failed" : isCurrent ? "current" : "" }
    }

    private let all: [Row]
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            let keep = selectedRow?.id
            rows = Self.filter(all, query)
            selection = rows.firstIndex { $0.id == keep } ?? (rows.isEmpty ? nil : 0)
        }
    }
    private(set) var rows: [Row]
    /// An index into `rows`.
    var selection: Int?

    init(presets: [VisualizationPreset], currentID: String?, failedIDs: Set<String>) {
        all = presets.map { Row(preset: $0, isCurrent: $0.id == currentID, isFailed: failedIDs.contains($0.id)) }
        rows = all
        selection = all.firstIndex { $0.isCurrent } ?? (all.isEmpty ? nil : 0)
    }

    var selectedRow: Row? { selection.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    /// ↑ (`-1`) or ↓ (`+1`), clamped.
    func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        let index = (selection ?? (step > 0 ? -1 : rows.count)) + step
        selection = min(max(index, 0), rows.count - 1)
    }

    /// Names containing `query`, ignoring case and diacritics; all rows for an empty query.
    static func filter(_ rows: [Row], _ query: String) -> [Row] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return rows }
        return rows.filter { $0.preset.name.localizedStandardContains(text) }
    }
}
