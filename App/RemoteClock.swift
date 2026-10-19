import SwiftUI

/// Re-evaluates `content` once a second while `anchor` is set (a non-local output playing), else once.
/// Without an anchor there is no TimelineView, so This Mac playback, pause and idle add no wakeups.
struct RemoteClock<Content: View>: View {
    let anchor: Date?
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if let anchor {
            TimelineView(.periodic(from: anchor, by: 1)) { content($0.date) }
        } else {
            content(Date())
        }
    }
}
