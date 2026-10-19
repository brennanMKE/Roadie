import Foundation
import MusicBackendKit
import Observation

/// The Library's Output menu: This Mac, then the remote backend's speakers, then its groups. Never connects: it lists
/// remote players only while the remote backend is already connected (the Library connects it).
@MainActor @Observable
public final class OutputPickerModel {
    public static let notConnectedHint = "Open the Library to connect to Music Assistant."

    /// This Mac first, then speakers by name, then groups by name. Unavailable players are listed (shown disabled).
    public private(set) var devices: [OutputDevice] = [OutputDevice.thisMac]
    /// Why only This Mac is listed (not connected, or the listing failed). Never an alert.
    public private(set) var hint: String? = OutputPickerModel.notConnectedHint

    public var speakers: [OutputDevice] { devices.filter { $0.id != OutputDevice.thisMacID && !$0.isGroup } }
    public var groups: [OutputDevice] { devices.filter { $0.id != OutputDevice.thisMacID && $0.isGroup } }

    @ObservationIgnored private let remote: any MusicBackend
    @ObservationIgnored private let isConnected: @Sendable () async -> Bool
    @ObservationIgnored private var generation = 0

    public init(remote: any MusicBackend, isConnected: @escaping @Sendable () async -> Bool) {
        self.remote = remote
        self.isConnected = isConnected
    }

    public func refresh() async {
        generation += 1
        let mine = generation
        guard await isConnected() else {
            guard mine == generation else { return }
            devices = [OutputDevice.thisMac]
            hint = Self.notConnectedHint
            return
        }
        do {
            let listed = try await remote.outputs()
            guard mine == generation else { return }
            let others = listed.filter { $0.id != OutputDevice.thisMacID }
            func byName(_ a: OutputDevice, _ b: OutputDevice) -> Bool {
                a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            devices = [OutputDevice.thisMac] + others.filter { !$0.isGroup }.sorted(by: byName)
                + others.filter(\.isGroup).sorted(by: byName)
            hint = nil
        } catch {
            guard mine == generation, !(error is CancellationError) else { return }
            devices = [OutputDevice.thisMac]
            hint = (error as? any LocalizedError)?.errorDescription ?? "Could not list the speakers."
        }
    }

    /// `selected`, or This Mac when it is no longer listed.
    public func reconcile(selected: OutputDevice.ID) -> OutputDevice.ID {
        devices.contains { $0.id == selected } ? selected : OutputDevice.thisMacID
    }
}
