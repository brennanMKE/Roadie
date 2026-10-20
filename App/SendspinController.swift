import AppKit
import Foundation
import MusicAssistantKit
import Observation
import SendspinKit
import SendspinPlayback
import os

/// Starts and stops SkinAmp's Sendspin session, which makes This Mac a Music Assistant player (#0109). It connects
/// only when the Music Assistant API does (the Library or a probe), never at launch: no Keychain read, no socket.
@MainActor
@Observable
final class SendspinController {
    static let enabledKey = "sendspin.enabled"

    let sendspin: SendspinPlayer
    /// The MA player name: "SkinAmp (<computer name>)".
    let identity: SendspinIdentity
    /// Settings › Music Assistant › Play Music Assistant on this Mac. Default on.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reevaluate()
        }
    }

    @ObservationIgnored private let musicAssistant: MusicAssistantBackend
    /// The base URL of the running session; nil when none runs.
    @ObservationIgnored private var runningURL: URL?
    /// Decisions run one after another so a fast connect / disconnect never interleaves a start and a stop.
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "Sendspin")

    init(sendspin: SendspinPlayer, musicAssistant: MusicAssistantBackend, defaults: UserDefaults = .standard) {
        self.sendspin = sendspin
        self.musicAssistant = musicAssistant
        identity = SendspinIdentity.load(defaults: defaults, hostName: Host.current().localizedName ?? "Mac")
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Follows the Music Assistant connection, sleep and wake. Called once by `PlayerModel`.
    func start() {
        let ma = musicAssistant
        watchTask = Task { [weak self] in
            for await state in await ma.connectionStates() {
                guard let self else { return }
                switch state {
                case .connected: self.reevaluate()
                case .failed, .disconnected: self.stopSession(reason: .restart)
                default: break
                }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSession(reason: .restart) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    /// The selection picked another server (#0075): drop the session; the next `.connected` starts it on the new one.
    func serverChanged() { stopSession(reason: .restart) }

    /// On quit: says goodbye, but never holds quit up for more than 0.5 s.
    func shutdown() {
        let sendspin = sendspin
        let done = Task { await sendspin.stop(reason: .shutdown) }
        let deadline = Date().addingTimeInterval(0.5)
        final class Flag { var isSet = false }
        let finished = Flag()
        Task { @MainActor in
            await done.value
            finished.isSet = true
        }
        while !finished.isSet, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        runningURL = nil
    }

    /// What Settings shows.
    var statusText: String {
        switch sendspin.status {
        case .off: "Off"
        case .connecting: "Connecting\u{2026}"
        case .connected: "Connected: shows in Music Assistant as \(identity.name)"
        case .failed(let message): message
        }
    }

    private func enqueue(_ operation: @escaping @MainActor (SendspinController) async -> Void) {
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
    }

    private func reevaluate() {
        enqueue { controller in await controller.decide() }
    }

    private func stopSession(reason: SendspinGoodbyeReason) {
        enqueue { controller in
            guard controller.runningURL != nil else { return }
            await controller.halt(reason: reason)
        }
    }

    private func decide() async {
        let endpoint = await musicAssistant.sendspinEndpoint()
        switch SendspinAutoConnect.decide(enabled: isEnabled, endpointURL: endpoint?.baseURL, runningURL: runningURL) {
        case .start:
            if let endpoint { await begin(endpoint) }
        case .restart:
            await halt(reason: .restart)
            if let endpoint { await begin(endpoint) }
        case .stop:
            await halt(reason: isEnabled ? .restart : .userRequest)
        case .none:
            break
        }
    }

    private func begin(_ endpoint: MusicAssistantSendspinEndpoint) async {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let configuration = SendspinConnectionConfiguration(
            baseURL: endpoint.baseURL, token: endpoint.token.rawValue, clientID: identity.clientID, name: identity.name,
            deviceInfo: SendspinDeviceInfo(productName: "SkinAmp", manufacturer: "SkinAmp", softwareVersion: version),
            format: sendspin.advertisedFormat())
        log.info("Sendspin starting")
        sendspin.start(configuration)
        runningURL = endpoint.baseURL
        await musicAssistant.setLocalSendspinClientID(identity.clientID)
    }

    private func halt(reason: SendspinGoodbyeReason) async {
        log.info("Sendspin stopping")
        runningURL = nil
        await musicAssistant.setLocalSendspinClientID(nil)
        await sendspin.stop(reason: reason)
    }
}
