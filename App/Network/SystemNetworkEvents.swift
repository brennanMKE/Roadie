import Foundation
import MusicAssistantKit
import Network

/// `NWPathMonitor` behind `NetworkChangeSource` (#0075). Yields once per path update after the first (the current
/// path when monitoring starts is not a change). Never reads or logs interface names or addresses. A Wi-Fi network
/// change, Ethernet, and Tailscale's utun coming up or going down all update the path, so CoreWLAN events are not
/// needed; the selection debounces the bursts.
struct SystemNetworkEvents: NetworkChangeSource {
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let monitor = MonitorBox()
        monitor.start { continuation.yield() }
        continuation.onTermination = { _ in monitor.cancel() }
        return stream
    }
}

/// Owns one monitor; its state is touched only on `queue`.
private final class MonitorBox: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "co.sstools.roadie.network-path")
    private var sawInitialPath = false

    func start(_ onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [self] _ in
            guard sawInitialPath else {
                sawInitialPath = true
                return
            }
            onChange()
        }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }
}
