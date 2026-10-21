import Foundation
import MusicBackendKit
import Testing
@testable import LibraryBrowser

/// #0121: which output SkinAmp adopts from Music Assistant, and what an exclusive start stops.
struct PlaybackOwnershipTests {
    let mac = OutputDevice.thisMacID
    let homePod = OutputDevice.ID(rawValue: "homepod")
    let kitchen = OutputDevice.ID(rawValue: "kitchen")
    let group = OutputDevice.ID(rawValue: "group")

    private func activity(
        _ output: OutputDevice.ID, _ state: NowPlaying.State, leader: OutputDevice.ID? = nil, at time: Double? = nil
    ) -> OutputActivity {
        OutputActivity(output: output, name: output.rawValue, state: state, leader: leader, updatedAt: time)
    }

    // MARK: Adoption

    @Test func launchAdoptsThePlayingSpeaker() {
        let adopted = PlaybackOwnership.adoption(
            selected: mac, selectedState: .stopped, activity: [activity(mac, .stopped), activity(homePod, .playing)],
            trigger: .connected)
        #expect(adopted == homePod)
    }

    @Test func launchAdoptsAPausedSpeakerWhenNothingPlays() {
        let adopted = PlaybackOwnership.adoption(
            selected: mac, selectedState: .stopped, activity: [activity(homePod, .paused), activity(kitchen, .stopped)],
            trigger: .connected)
        #expect(adopted == homePod)
    }

    @Test func launchKeepsLocalPlaybackOnThisMac() {
        let adopted = PlaybackOwnership.adoption(
            selected: mac, selectedState: .playing, activity: [activity(homePod, .playing)], trigger: .connected)
        #expect(adopted == nil)
        // Paused locally: a paused speaker doesn't take over either.
        #expect(
            PlaybackOwnership.adoption(
                selected: mac, selectedState: .paused, activity: [activity(homePod, .paused)], trigger: .connected)
                == nil)
    }

    @Test func connectedPrefersTheMostRecentlyUpdatedPlayer() {
        let adopted = PlaybackOwnership.adoption(
            selected: mac, selectedState: .stopped,
            activity: [activity(homePod, .playing, at: 100), activity(kitchen, .playing, at: 200)], trigger: .connected)
        #expect(adopted == kitchen)
    }

    @Test func adoptionPicksTheLeaderNotAMember() {
        let adopted = PlaybackOwnership.adoption(
            selected: mac, selectedState: .stopped,
            activity: [activity(homePod, .playing, leader: group, at: 300), activity(group, .playing, at: 100)],
            trigger: .connected)
        #expect(adopted == group)
    }

    @Test func externalStartIsAdoptedWhileTheTargetIsStopped() {
        let previous = [activity(homePod, .stopped), activity(kitchen, .stopped)]
        let adopted = PlaybackOwnership.adoption(
            selected: homePod, selectedState: .stopped, activity: [activity(homePod, .stopped), activity(kitchen, .playing)],
            trigger: .activityChanged(previous: previous))
        #expect(adopted == kitchen)
    }

    @Test func alreadyPlayingRoomDoesNotStealTheTarget() {
        let current = [activity(homePod, .stopped), activity(kitchen, .playing)]
        let adopted = PlaybackOwnership.adoption(
            selected: homePod, selectedState: .stopped, activity: current, trigger: .activityChanged(previous: current))
        #expect(adopted == nil)
    }

    @Test func externalPauseOfTheTargetKeepsIt() {
        let previous = [activity(homePod, .playing), activity(kitchen, .playing)]
        let adopted = PlaybackOwnership.adoption(
            selected: homePod, selectedState: .paused, activity: [activity(homePod, .paused), activity(kitchen, .playing)],
            trigger: .activityChanged(previous: previous))
        #expect(adopted == nil)
    }

    // MARK: Exclusive start

    @Test func startingOnSpeakerStopsLocalPlaybackOnThisMac() {
        let stops = PlaybackOwnership.stops(
            startingOn: homePod, previous: mac, thisMacFeed: .local, thisMacSounding: true, activity: [])
        #expect(stops == [.thisMacLocal])
    }

    @Test func startingOnSpeakerStopsThisMacsMusicAssistantStream() {
        let stops = PlaybackOwnership.stops(
            startingOn: homePod, previous: mac, thisMacFeed: .musicAssistant, thisMacSounding: true,
            activity: [activity(mac, .playing)])
        #expect(stops == [.musicAssistant(mac)])
    }

    @Test func startingOnSpeakerSkipsThisMacSyncedToIt() {
        let stops = PlaybackOwnership.stops(
            startingOn: homePod, previous: mac, thisMacFeed: .musicAssistant, thisMacSounding: true,
            activity: [activity(mac, .playing, leader: homePod), activity(homePod, .playing)])
        #expect(stops.isEmpty)
    }

    @Test func startingOnThisMacStopsThePreviousSpeaker() {
        let stops = PlaybackOwnership.stops(
            startingOn: mac, previous: homePod, thisMacFeed: .local, thisMacSounding: false,
            activity: [activity(homePod, .playing)])
        #expect(stops == [.musicAssistant(homePod)])
    }

    @Test func startingLeavesUnrelatedPlayersAlone() {
        let stops = PlaybackOwnership.stops(
            startingOn: homePod, previous: mac, thisMacFeed: .local, thisMacSounding: false,
            activity: [activity(kitchen, .playing), activity(homePod, .stopped)])
        #expect(stops.isEmpty)
        // A previous speaker that already stopped needs nothing either.
        #expect(
            PlaybackOwnership.stops(
                startingOn: mac, previous: kitchen, thisMacFeed: .local, thisMacSounding: false,
                activity: [activity(kitchen, .stopped)]
            ).isEmpty)
    }

    @Test func startingOnAGroupKeepsItsMember() {
        // The member was the target and now plays as part of the group that is starting.
        let stops = PlaybackOwnership.stops(
            startingOn: group, previous: homePod, thisMacFeed: .local, thisMacSounding: false,
            activity: [activity(homePod, .playing, leader: group), activity(group, .playing)])
        #expect(stops.isEmpty)
        // And the reverse: starting on a member of the previous group.
        #expect(
            PlaybackOwnership.stops(
                startingOn: homePod, previous: group, thisMacFeed: .local, thisMacSounding: false,
                activity: [activity(homePod, .playing, leader: group), activity(group, .playing)]
            ).isEmpty)
    }
}
