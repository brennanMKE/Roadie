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

    /// The rows `index` was built from.
    private var indexedTracks: [Track] = []
    private var index = JumpToFileIndex([])
    /// The rows the table shows: `results` are indices into `shownTracks`, the full queue.
    private var shownTracks: [Track] = []
    private var results: [Int] = []
    private var indexTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    /// Bumped on each show and close, so a stale observation doesn't re-arm itself.
    private var observationID = 0
    private var isObserving = false

    func show(model: PlayerModel) {
        self.model = model
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

    private func rebuild() {
        guard let model else { return }
        let tracks = model.playlist.tracks
        let entries = tracks.map(Self.entry)
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { JumpToFileIndex(entries) }.value
            guard !Task.isCancelled, let self else { return }
            self.indexedTracks = tracks
            self.index = built
            self.filter()
        }
    }

    private static func entry(_ track: Track) -> JumpToFileEntry {
        var fileName = ""
        if case .file(let url) = track.source, url.isFileURL { fileName = url.lastPathComponent }
        return JumpToFileEntry(artist: track.artist, title: track.title, album: track.album ?? "", fileName: fileName)
    }

    private func filter() {
        filterTask?.cancel()
        let query = searchField.stringValue
        let index = self.index
        let tracks = indexedTracks
        filterTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                index.matches(query, isCancelled: { Task.isCancelled })
            }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let found, !Task.isCancelled, let self, self.searchField.stringValue == query else { return }
            self.apply(found, tracks: tracks)
        }
    }

    private func apply(_ found: [Int], tracks: [Track]) {
        let selectedID = table.selectedRowIndexes.first.flatMap { row in
            results.indices.contains(row) ? shownTracks[results[row]].id : nil
        }
        shownTracks = tracks
        results = found
        table.reloadData()
        if found.isEmpty {
            table.deselectAll(nil)
        } else {
            let row = selectedID.flatMap { id in found.firstIndex { tracks[$0].id == id } } ?? 0
            select(row)
        }
        updateEmptyState()
        updateQueueButton()
    }

    /// Queue works on any listed queue; on a Music Assistant queue it moves the rows after the current item (#0182).
    private var canQueue: Bool {
        guard let model else { return false }
        return model.queueRowsSource != QueueRowsSource.none
    }

    /// The selected results' queue indices in result (playlist) order, else the first result.
    private var selectedIndices: [Int] {
        let rows = table.selectedRowIndexes.filter { results.indices.contains($0) }
        if rows.isEmpty { return results.first.map { [$0] } ?? [] }
        return rows.map { results[$0] }
    }

    /// "Dequeue" when every selected result is already queued, like the playlist menu's `selectionIsQueued`.
    private func updateQueueButton() {
        queueButton.isEnabled = !results.isEmpty && canQueue
        guard let model, model.playlist.remote == nil else {
            queueButton.title = "Queue"
            return
        }
        let queue = model.player.queue
        let indices = selectedIndices.filter { shownTracks.indices.contains($0) }
        let allQueued = !indices.isEmpty && indices.allSatisfy { queue.upNextPosition(of: shownTracks[$0].id) != nil }
        queueButton.title = allQueued ? "Dequeue" : "Queue"
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateQueueButton() }

    private func updateEmptyState() {
        let text: String? =
            if model?.queueRowsSource == QueueRowsSource.none { "This speaker\u{2019}s queue can\u{2019}t be listed" }
            else if shownTracks.isEmpty { "The playlist is empty. Add music from the Library (\u{2318}L) or File \u{203A} Open." }
            else if results.isEmpty { "No matches" }
            else { nil }
        emptyLabel.stringValue = text ?? ""
        emptyLabel.isHidden = text == nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    /// Each row carries `jump.row.N` (N: the table row) for XCUITest (#0199).
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.setAccessibilityIdentifier(AXID.Jump.row(row))
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, results.indices.contains(row) else { return nil }
        let index = results[row]
        let track = shownTracks[index]
        let field = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? makeCell(id)
        switch id {
        case .number: field.stringValue = "\(index + 1)"
        case .time: field.stringValue = PlaylistText.time(track.duration > 0 ? track.duration : nil)
        case .marker:
            field.stringValue =
                model?.playlist.remote == nil
                ? PlaylistText.queueMarker(model?.player.queue.upNextPosition(of: track.id)) : ""
        default: field.stringValue = PlaylistModel.displayName(track)
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
        guard !results.isEmpty else { return }
        let current = table.selectedRowIndexes.first ?? (delta > 0 ? -1 : results.count)
        select(min(max(current + delta, 0), results.count - 1))
    }

    private var pageRows: Int {
        let height = table.enclosingScrollView?.contentView.bounds.height ?? 0
        return max(1, Int(height / (table.rowHeight + table.intercellSpacing.height)) - 1)
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) { filter() }

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
        let row = table.selectedRowIndexes.first ?? 0
        guard results.indices.contains(row), let model else {
            NSSound.beep()
            return
        }
        let index = results[row]
        model.playlist.playRow(index)
        model.playlist.reveal(index)
        panel?.performClose(nil)
    }

    /// Toggles the selected results in the play-next list (like the playlist's Q), leaving the panel open.
    @objc private func queueSelected() {
        let indices = selectedIndices
        guard canQueue, !indices.isEmpty, let model else {
            NSSound.beep()
            return
        }
        model.playlist.toggleQueue(indices)
        updateQueueButton()
        if panel?.firstResponder !== searchField.currentEditor() { panel?.makeFirstResponder(searchField) }
    }

    func windowWillClose(_ notification: Notification) {
        isObserving = false
        observationID += 1
        indexTask?.cancel()
        filterTask?.cancel()
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
