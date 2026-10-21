import MusicBackendKit
import Testing
@testable import LibraryBrowser

/// #0118: checking several outputs, and the steps that get Music Assistant there.
struct OutputSelectionTests {
    let mac = OutputDevice.thisMacID
    let kitchen = OutputDevice.ID(rawValue: "kitchen")
    let bedroom = OutputDevice.ID(rawValue: "bedroom")
    let office = OutputDevice.ID(rawValue: "office")
    let downstairs = OutputDevice.ID(rawValue: "downstairs")

    var devices: [OutputDevice] {
        [
            .thisMac,
            OutputDevice(id: kitchen, name: "Kitchen", kind: .remote),
            OutputDevice(id: bedroom, name: "Bedroom", kind: .remote),
            OutputDevice(id: office, name: "Office", kind: .remote),
            OutputDevice(id: downstairs, name: "Downstairs", kind: .remote, isGroup: true),
        ]
    }

    @Test func startsWithThisMacAlone() {
        #expect(OutputSelection.thisMac.all == [mac])
        #expect(OutputSelection.thisMac.members.isEmpty)
    }

    @Test func checkingASpeakerAddsItBehindTheLeader() {
        let (next, steps) = OutputSelection.thisMac.toggling(kitchen, devices: devices)
        #expect(next.all == [mac, kitchen])
        #expect(steps == [.setMembers(leader: mac, add: [kitchen], remove: [])])
    }

    @Test func uncheckingAMemberRemovesOnlyIt() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom, office])
        let (next, steps) = selection.toggling(bedroom, devices: devices)
        #expect(next.all == [kitchen, office])
        #expect(steps == [.setMembers(leader: kitchen, add: [], remove: [bedroom])])
    }

    @Test func uncheckingTheLastOutputIsIgnored() {
        let selection = OutputSelection(leader: kitchen)
        let (next, steps) = selection.toggling(kitchen, devices: devices)
        #expect(next == selection)
        #expect(steps.isEmpty)
    }

    @Test func uncheckingTheLeaderPromotesTheNextMember() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom, office, mac])
        let (next, steps) = selection.toggling(kitchen, devices: devices)
        #expect(next.leader == bedroom)
        #expect(next.members == [office, mac])
        #expect(
            steps == [
                .setMembers(leader: kitchen, add: [], remove: [bedroom, office, mac]),
                .move(to: bedroom),
                .setMembers(leader: bedroom, add: [office, mac], remove: []),
            ])
    }

    @Test func uncheckingTheLeaderOfAPairSkipsTheRegroup() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom])
        let (next, steps) = selection.toggling(kitchen, devices: devices)
        #expect(next.all == [bedroom])
        #expect(steps == [.setMembers(leader: kitchen, add: [], remove: [bedroom]), .move(to: bedroom)])
    }

    @Test func pickingAGroupReplacesTheSelection() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom])
        let (next, steps) = selection.toggling(downstairs, devices: devices)
        #expect(next.all == [downstairs])
        #expect(steps == [.setMembers(leader: kitchen, add: [], remove: [bedroom]), .move(to: downstairs)])
    }

    @Test func checkingASpeakerWhileAGroupIsSelectedReplacesIt() {
        let (next, steps) = OutputSelection(leader: downstairs).toggling(kitchen, devices: devices)
        #expect(next.all == [kitchen])
        #expect(steps == [.move(to: kitchen)])
    }

    @Test func selectingOnlyUngroupsThenMoves() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom])
        let (next, steps) = selection.selectingOnly(mac)
        #expect(next == .thisMac)
        #expect(steps == [.setMembers(leader: kitchen, add: [], remove: [bedroom]), .move(to: mac)])
    }

    @Test func selectingOnlyTheLeaderJustUngroups() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom, office])
        let (next, steps) = selection.selectingOnly(kitchen)
        #expect(next.all == [kitchen])
        #expect(steps == [.setMembers(leader: kitchen, add: [], remove: [bedroom, office])])
    }

    @Test func labelNamesOneOrCountsTheRest() {
        let listed = devices
        let names: (OutputDevice.ID) -> String = { id in listed.first { $0.id == id }?.name ?? "?" }
        #expect(OutputSelection(leader: kitchen).label(names: names) == "Kitchen")
        #expect(OutputSelection(leader: kitchen, members: [bedroom]).label(names: names) == "Kitchen + 1")
        #expect(OutputSelection(leader: mac, members: [kitchen, bedroom]).label(names: names) == "This Mac + 2")
    }

    @Test func reconcileDropsMissingMembersAndPromotesTheNext() {
        var listed = devices.filter { $0.id != kitchen }
        if let index = listed.firstIndex(where: { $0.id == office }) { listed[index].isAvailable = false }
        let selection = OutputSelection(leader: kitchen, members: [office, bedroom, mac])
        let next = selection.reconciled(with: listed)
        #expect(next.leader == bedroom)
        #expect(next.members == [mac])
    }

    @Test func reconcileFallsBackToThisMacWhenEveryoneIsGone() {
        let selection = OutputSelection(leader: kitchen, members: [bedroom])
        #expect(selection.reconciled(with: [.thisMac]) == .thisMac)
    }

    @Test func speakersThatCannotGroupWithTheSelectionAreNotAddable() {
        let selection = OutputSelection(leader: mac, members: [kitchen])
        let joinsBoth = OutputDevice(id: bedroom, name: "Bedroom", kind: .remote, groupableWith: [mac, kitchen])
        let joinsMacOnly = OutputDevice(id: bedroom, name: "Bedroom", kind: .remote, groupableWith: [mac])
        let unknown = OutputDevice(id: bedroom, name: "Bedroom", kind: .remote)
        let offline = OutputDevice(id: bedroom, name: "Bedroom", kind: .remote, isAvailable: false)
        let group = OutputDevice(id: downstairs, name: "Downstairs", kind: .remote, isGroup: true)
        #expect(OutputSelection.canAdd(joinsBoth, to: selection))
        #expect(!OutputSelection.canAdd(joinsMacOnly, to: selection))
        #expect(OutputSelection.canAdd(unknown, to: selection))
        #expect(!OutputSelection.canAdd(offline, to: selection))
        #expect(!OutputSelection.canAdd(group, to: selection))
    }
}
