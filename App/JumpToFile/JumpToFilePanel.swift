import AppKit
import AudioCore
import LibraryBrowser
import Observation
import SkinKit

private extension NSUserInterfaceItemIdentifier {
    static let number = NSUserInterfaceItemIdentifier("number")
    static let name = NSUserInterfaceItemIdentifier("name")
    static let marker = NSUserInterfaceItemIdentifier("marker")
    static let time = NSUserInterfaceItemIdentifier("time")
}

/// Winamp's Jump to File (J, ⌘J, #0176): a search field over the playlist editor's rows. Return or a double-click
/// plays the row, which the playlist editor then selects and scrolls to. AppKit, so a 50,000-row queue stays fast:
/// the table asks only for visible rows, and the index is built and filtered off the main actor.
@MainActor
final class JumpToFilePanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    static let shared = JumpToFilePanel()
    private static let autosaveName = "JumpToFilePanel"

    private var panel: NSPanel?
    private weak var model: PlayerModel?
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let queueButton = NSButton(title: "Queue", target: nil, action: nil)

    /// The query, results, selection and actions (#0210).
    private var controller: JumpToFileController?
    /// Bumped on each show and close, so a stale observation doesn't re-arm itself.
    private var observationID = 0
    private var isObserving = false

    func show(model: PlayerModel) {
        self.model = model
        if controller?.model !== model {
            controller?.cancel()
            let controller = JumpToFileController(model: model)
            controller.onResultsChanged = { [weak self] in self?.resultsChanged() }
            controller.onClose = { [weak self] in self?.panel?.performClose(nil) }
            self.controller = controller
        }
        let panel = self.panel ?? makePanel()
        if self.panel == nil {
            self.panel = panel
            let restored = panel.setFrameUsingName(Self.autosaveName)
            panel.setFrameAutosaveName(Self.autosaveName)
            if !restored { panel.center() }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.selectText(nil)
        if !isObserving {
            isObserving = true
            observationID += 1
            observe(observationID)
        }
        rebuild()
    }

    /// What the state probe reports while the panel is on screen (#0204); nil when it is closed.
    var probe: TestProbe.JumpProbe? {
        guard let panel, panel.isVisible, let controller else { return nil }
        return TestProbe.JumpProbe(
            results: controller.results.map(\.index),
            selected: controller.selectedRows.compactMap { controller.results.indices.contains($0) ? controller.results[$0].index : nil },
            empty: controller.emptyStateText, queueTitle: queueButton.title)
    }

    // MARK: Data

    private func observe(_ id: Int) {
        observeRows(id)
        observeUpNext(id)
    }

    private func observeRows(_ id: Int) {
        guard isObserving, id == observationID, let model else { return }
        withObservationTracking {
            _ = model.playlist.tracks
            _ = model.queueRowsSource
        } onChange: { [weak self] in
            Task { @MainActor in self?.queueChanged(id) }
        }
    }

    private func queueChanged(_ id: Int) {
        guard isObserving, id == observationID else { return }
        observeRows(id)
        rebuild()
    }

    /// The play-next list changes markers only, so it reloads the visible marker cells, not the index.
    private func observeUpNext(_ id: Int) {
        guard isObserving, id == observationID, let model else { return }
        withObservationTracking {
            _ = model.player.queue.upNext
        } onChange: { [weak self] in
            Task { @MainActor in self?.upNextChanged(id) }
        }
    }

    private func upNextChanged(_ id: Int) {
        guard isObserving, id == observationID else { return }
        observeUpNext(id)
        let column = table.column(withIdentifier: .marker)
        let visible = table.rows(in: table.visibleRect)
        if column >= 0, visible.length > 0 {
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [column])
        }
        updateQueueButton()
    }

    private func rebuild() { controller?.rebuild() }

    private func resultsChanged() {
        guard let controller else { return }
        table.reloadData()
        if let row = controller.selectedRows.first { select(row) } else { table.deselectAll(nil) }
        updateEmptyState()
        updateQueueButton()
    }

    private func updateQueueButton() {
        queueButton.isEnabled = controller?.isQueueEnabled ?? false
        queueButton.title = controller?.queueButtonTitle ?? "Queue"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        controller?.selectedRows = table.selectedRowIndexes
        updateQueueButton()
    }

    private func updateEmptyState() {
        let text = controller?.emptyStateText
        emptyLabel.stringValue = text ?? ""
        emptyLabel.isHidden = text == nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { controller?.results.count ?? 0 }

    /// Each row carries `jump.row.N` (N: the table row) for XCUITest (#0199).
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.setAccessibilityIdentifier(AXID.Jump.row(row))
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let controller, controller.results.indices.contains(row) else { return nil }
        let index = controller.results[row].index
        let track = controller.shownTracks[index]
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? makeCell(id)
        switch id {
        case .number: field.stringValue = "\(index + 1)"
        case .time: field.stringValue = PlaylistText.time(track.duration > 0 ? track.duration : nil)
        case .marker: field.stringValue = controller.marker(for: index)
        default: field.stringValue = controller.results[row].name
        }
        return field
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.identifier = id
        field.lineBreakMode = .byTruncatingTail
        if id != .name {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        return field
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func move(by delta: Int) {
        if let row = controller?.row(movingBy: delta) { select(row) }
    }

    private var pageRows: Int {
        let height = table.enclosingScrollView?.contentView.bounds.height ?? 0
        return max(1, Int(height / (table.rowHeight + table.intercellSpacing.height)) - 1)
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) { controller?.query = searchField.stringValue }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(by: -pageRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(by: pageRows)
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { queueSelected() } else { playSelected() }
        case #selector(NSResponder.cancelOperation(_:)): panel?.performClose(nil)
        default: return false
        }
        return true
    }

    /// Plays the first selected match, else the first match. Uses the playlist's own play path (local or remote).
    @objc private func playSelected() {
        if controller?.playSelected() != true { NSSound.beep() }
    }

    /// Toggles the selected results in the play-next list (like the playlist's Q), leaving the panel open.
    @objc private func queueSelected() {
        guard controller?.toggleQueueSelected() == true else {
            NSSound.beep()
            return
        }
        updateQueueButton()
        if panel?.firstResponder !== searchField.currentEditor() { panel?.makeFirstResponder(searchField) }
    }

    func windowWillClose(_ notification: Notification) {
        isObserving = false
        observationID += 1
        controller?.cancel()
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Jump to File"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 320, height: 200)
        panel.level = .floating
        panel.delegate = self

        searchField.placeholderString = "Type to filter the playlist"
        searchField.delegate = self

        for (id, width) in [(NSUserInterfaceItemIdentifier.number, 48.0), (.name, 220.0), (.marker, 40.0), (.time, 52.0)] {
            let column = NSTableColumn(identifier: id)
            column.width = width
            column.resizingMask = id == .name ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true
        searchField.setAccessibilityIdentifier(AXID.Jump.search)
        table.setAccessibilityIdentifier(AXID.Jump.table)
        emptyLabel.setAccessibilityIdentifier(AXID.Jump.empty)
        queueButton.setAccessibilityIdentifier(AXID.Jump.queue)

        let play = NSButton(title: "Play", target: self, action: #selector(playSelected))
        let queue = queueButton
        queue.target = self
        queue.action = #selector(queueSelected)
        let close = NSButton(title: "Close", target: panel, action: #selector(NSWindow.performClose(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [play, queue, spacer, close])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [searchField, scroll, emptyLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [searchField, scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        panel.contentView = stack
        return panel
    }
}
