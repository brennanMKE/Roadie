import AppKit
import SwiftUI
import VisualizationKit

/// The preset list over the picture (#0240): a search field and the presets, current one selected. The search field
/// keeps focus; ↑ ↓ move the selection, Return loads it, Esc closes, ⌥Return still toggles full screen.
struct VisualizationPresetListView: View {
    @Bindable var list: PresetListModel
    let onLoad: () -> Void
    let onClose: () -> Void
    let onToggleFullScreen: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            panel
                .frame(maxWidth: 480, maxHeight: geometry.size.height * 0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            TextField("Search Presets", text: $list.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier(AXID.Vis.browserSearch)
                .onKeyPress(.upArrow) { list.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { list.moveSelection(by: 1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.option) { onToggleFullScreen() } else { onLoad() }
                    return .handled
                }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onSubmit { onLoad() }
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, index: index)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: list.selection) { scroll(proxy) }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Vis.browser)
        .onAppear {
            searchFocused = true
            Task { @MainActor in searchFocused = true }
        }
    }

    private func rowView(_ row: PresetListModel.Row, index: Int) -> some View {
        let selected = list.selection == index
        return HStack {
            Text(row.preset.name)
                .lineLimit(1)
            Spacer()
            if row.isFailed {
                Text("Couldn't load").foregroundStyle(.secondary)
            }
            Text(row.sourceTag).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .opacity(row.isFailed ? 0.5 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            list.selection = index
            onLoad()
        }
        .onTapGesture { list.selection = index }
        // Static text, so the value lands in AXValue where XCUITest reads it (#0200's `skinDisplay`).
        .skinDisplay(AXID.Vis.browserRow(index), label: row.preset.name, value: row.status)
        // The cursor row is announced through the hint, so the row stays plain static text for the value.
        .accessibilityHint(selected ? "Selected" : "")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if let id = list.selectedRow?.id { proxy.scrollTo(id, anchor: .center) }
    }
}

extension VisualizationHostView {
    private static let listIdentifier = NSUserInterfaceItemIdentifier("vis.presetListHost")

    /// Shows the list over the picture, or removes it (nil), handing the keys back to this view.
    func setPresetList(_ list: PresetListModel?, model: VisualizationModel) {
        let existing = subviews.first { $0.identifier == Self.listIdentifier }
        guard let list else {
            if let existing {
                existing.removeFromSuperview()
                window?.makeFirstResponder(self)
            }
            return
        }
        existing?.removeFromSuperview()
        let view = VisualizationPresetListView(
            list: list,
            onLoad: { [weak model] in model?.loadListSelection() },
            onClose: { [weak model] in model?.closeList() },
            onToggleFullScreen: { [weak model] in model?.perform(.toggleFullScreen) })
        let host = NSHostingView(rootView: view)
        host.identifier = Self.listIdentifier
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
}
