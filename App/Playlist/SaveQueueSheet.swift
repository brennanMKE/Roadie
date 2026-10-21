import AppKit

/// Asks for the new playlist's name before saving a queue to Music Assistant (#0140). A stand-in until W2's
/// `PlaylistNameSheet` (#0135) lands; then this can call that instead.
@MainActor
enum SaveQueueSheet {
    /// The trimmed name, or nil when cancelled. A sheet on the key window when there is one, else app-modal.
    static func askName(defaultName: String = "New Playlist") async -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Queue as Playlist"
        alert.informativeText = "The queue is saved as a new playlist in Music Assistant."
        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
