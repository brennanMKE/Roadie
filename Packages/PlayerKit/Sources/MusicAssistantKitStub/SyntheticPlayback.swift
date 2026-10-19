import Foundation
import MusicAssistantKit

/// "Playing" player and queue objects built from the recorded `player-get.json` and `player-queue-active.json`
/// with playback fields overridden.
///
/// SYNTHETIC until #0076 records a playing speaker: the recorded player is idle with `current_media: null`, so the
/// shape of `current_media` while playing comes from the API schema. Kept out of `Fixtures/`, which holds only
/// verbatim recordings.
public enum SyntheticPlayback {
    /// The recorded player (`players/get` answers it; any other id is null).
    public static let playerID = "ap223aed81fe30"

    public static func player(
        state: String = "playing", title: String? = "Synthetic Song", artist: String? = "Synthetic Artist",
        album: String? = "Synthetic Album", duration: Double? = 200, uri: String? = "library://track/7",
        imageURL: String? = "http://ma.example:8095/imageproxy/proxy123?size=512&fmt=jpg",
        volume: MAJSON = 20, supportedFeatures: [String]? = nil
    ) throws -> MAJSON {
        guard case .object(var object) = try recordedResult(.playerGet) else { return .null }
        object["playback_state"] = .string(state)
        object["volume_level"] = volume
        if let supportedFeatures { object["supported_features"] = .array(supportedFeatures.map { .string($0) }) }
        if title == nil && uri == nil {
            object["current_media"] = .null
        } else {
            var media: [String: MAJSON] = ["media_type": "track"]
            media["uri"] = uri.map { .string($0) } ?? .null
            media["title"] = title.map { .string($0) } ?? .null
            media["artist"] = artist.map { .string($0) } ?? .null
            media["album"] = album.map { .string($0) } ?? .null
            media["duration"] = duration.map { .number($0) } ?? .null
            media["image_url"] = imageURL.map { .string($0) } ?? .null
            object["current_media"] = .object(media)
        }
        return .object(object)
    }

    public static func queue(state: String = "playing", elapsed: Double = 30, lastUpdated: Double? = nil) throws -> MAJSON {
        guard case .object(var object) = try recordedResult(.playerQueueActive) else { return .null }
        object["state"] = .string(state)
        object["elapsed_time"] = .number(elapsed)
        object["elapsed_time_last_updated"] = lastUpdated.map { .number($0) } ?? .null
        return .object(object)
    }

    private static func recordedResult(_ fixture: MAFixture) throws -> MAJSON {
        try fixture.frames().first?["result"] ?? .null
    }
}

extension FixtureScript {
    /// Answers `command` with `result` ahead of every other route (later overrides win).
    public mutating func override(_ command: String, result: MAJSON) {
        routes.insert(.result(command: command, result), at: 0)
    }
}
