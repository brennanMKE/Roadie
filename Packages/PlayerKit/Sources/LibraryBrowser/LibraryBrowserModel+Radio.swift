import Foundation
import MusicBackendKit

extension LibraryBrowserModel {
    /// "Add Radio URL…" (#0147): adds the station, then refetches a loaded Radio list. Returns the failure text,
    /// nil on success.
    @discardableResult
    public func addRadio(url text: String, name: String = "") async -> String? {
        guard backend.capabilities.contains(.radio) else { return "This library has no radio stations." }
        guard let input = RadioURLInput.parse(text, name: name) else { return "Enter an http or https stream URL." }
        do {
            _ = try await backend.addRadio(url: input.url, name: input.name)
        } catch {
            return userMessage(for: error)
        }
        if radios.phase != .idle { radios.reload() }
        return nil
    }
}
