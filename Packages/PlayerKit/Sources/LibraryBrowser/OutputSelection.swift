import Foundation
import MusicBackendKit

/// The Output popover's selection (#0118): the leader (the old single `selectedOutput`) plus synced members.
public struct OutputSelection: Hashable, Sendable {
    public private(set) var leader: OutputDevice.ID
    /// Non-leader members, in the order they were checked.
    public private(set) var members: [OutputDevice.ID]
    public var all: [OutputDevice.ID] { [leader] + members }
    public static let thisMac = OutputSelection(leader: OutputDevice.thisMacID)

    public init(leader: OutputDevice.ID, members: [OutputDevice.ID] = []) {
        self.leader = leader
        self.members = members.filter { $0 != leader }
    }

    /// What the app must do, in order, to reach the new selection.
    public enum Step: Hashable, Sendable {
        case setMembers(leader: OutputDevice.ID, add: [OutputDevice.ID], remove: [OutputDevice.ID])
        /// #0117's move: set `selectedOutput`, which moves what plays.
        case move(to: OutputDevice.ID)
    }

    /// Checks or unchecks `id`. A group player selected, or `id` a group, works as `selectingOnly`.
    public func toggling(_ id: OutputDevice.ID, devices: [OutputDevice]) -> (OutputSelection, [Step]) {
        let isGroup: (OutputDevice.ID) -> Bool = { id in devices.first { $0.id == id }?.isGroup ?? false }
        if isGroup(id) || isGroup(leader) {
            return id == leader ? (self, []) : selectingOnly(id)
        }
        if id == leader {
            guard let next = members.first else { return (self, []) }
            let rest = Array(members.dropFirst())
            var steps: [Step] = [.setMembers(leader: leader, add: [], remove: members), .move(to: next)]
            if !rest.isEmpty { steps.append(.setMembers(leader: next, add: rest, remove: [])) }
            return (OutputSelection(leader: next, members: rest), steps)
        }
        if members.contains(id) {
            return (
                OutputSelection(leader: leader, members: members.filter { $0 != id }),
                [.setMembers(leader: leader, add: [], remove: [id])]
            )
        }
        return (OutputSelection(leader: leader, members: members + [id]), [.setMembers(leader: leader, add: [id], remove: [])])
    }

    /// The old single pick: ungroup, then move to `id`.
    public func selectingOnly(_ id: OutputDevice.ID) -> (OutputSelection, [Step]) {
        var steps: [Step] = []
        if !members.isEmpty { steps.append(.setMembers(leader: leader, add: [], remove: members)) }
        if id != leader { steps.append(.move(to: id)) }
        return (OutputSelection(leader: id), steps)
    }

    /// Drops members no longer listed or unavailable. A lost leader is replaced by the next member, or by This Mac.
    /// Never returns steps: the server already dropped those players.
    public func reconciled(with devices: [OutputDevice]) -> OutputSelection {
        let present: (OutputDevice.ID) -> Bool = { id in
            id == OutputDevice.thisMacID || devices.contains { $0.id == id && $0.isAvailable }
        }
        let kept = all.filter(present)
        guard let first = kept.first else { return .thisMac }
        return OutputSelection(leader: first, members: Array(kept.dropFirst()))
    }

    /// Whether `device` may be checked next to `selection`.
    public static func canAdd(_ device: OutputDevice, to selection: OutputSelection) -> Bool {
        guard device.isAvailable, !device.isGroup else { return false }
        guard let groupable = device.groupableWith else { return true }
        return selection.all.allSatisfy { $0 == device.id || groupable.contains($0) }
    }

    /// "Kitchen", or "Kitchen + 1" (the leader, then how many others).
    public func label(names: (OutputDevice.ID) -> String) -> String {
        members.isEmpty ? names(leader) : "\(names(leader)) + \(members.count)"
    }
}
