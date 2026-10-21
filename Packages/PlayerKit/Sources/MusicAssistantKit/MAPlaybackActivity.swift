import Foundation
import MusicBackendKit

/// `players/all` plus `player_queues/all` as SkinAmp's view of what plays where (#0121).
public enum MAPlaybackActivity {
    /// Enabled, visible players (and SkinAmp's own, as This Mac). A member's state comes from its leader's queue.
    public static func map(players: [MAPlayer], queues: [MAPlayerQueue], localClientID: String?) -> [OutputActivity] {
        let queuesByID = Dictionary(queues.map { ($0.queueID, $0) }, uniquingKeysWith: { _, last in last })
        let localPlayerID = localClientID.flatMap { id in
            (players.first { $0.hosts(sendspinClientID: id) && $0.available }
                ?? players.first { $0.hosts(sendspinClientID: id) })?.playerID
        }
        return players.compactMap { player in
            let isLocal = player.playerID == localPlayerID
            if !isLocal, player.enabled == false || player.hideInUI == true { return nil }
            let leaderID = (player.activeGroup ?? player.syncedTo).flatMap { $0 == player.playerID ? nil : $0 }
            let queue = queuesByID[leaderID ?? player.playerID]
            let leader = leaderID.map { id in
                id == localPlayerID ? OutputDevice.thisMacID : OutputDevice.ID(rawValue: id)
            }
            return OutputActivity(
                output: isLocal ? OutputDevice.thisMacID : OutputDevice.ID(rawValue: player.playerID),
                name: isLocal ? OutputDevice.thisMac.name : (player.displayName ?? player.name),
                state: MANowPlayingMapper.state(player: player, queue: queue), leader: leader,
                updatedAt: queue?.elapsedTimeLastUpdated ?? player.elapsedTimeLastUpdated)
        }
    }
}
