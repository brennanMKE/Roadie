import Foundation
import MusicBackendKit

/// Which Discover rows the sidebar lists (#0143, decision 7): the server's `enabled_by_default` rows, or every row
/// with the local Show all rows toggle. The server's order is kept.
public enum DiscoverRows {
    public static func visible(_ rows: [RecommendationRow], showAll: Bool) -> [RecommendationRow] {
        showAll ? rows : rows.filter(\.isEnabledByDefault)
    }

    /// How many rows Show all rows would add.
    public static func hiddenCount(_ rows: [RecommendationRow]) -> Int {
        rows.count { !$0.isEnabledByDefault }
    }
}
