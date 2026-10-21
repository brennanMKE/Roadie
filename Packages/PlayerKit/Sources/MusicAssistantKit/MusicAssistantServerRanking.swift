import Foundation

/// The pure half of automatic server choice (#0075): which servers to try in which order, and which probe result
/// wins. No I/O. The Wi-Fi name is only a hint: without it the order is the user's list order.
public struct MusicAssistantServerRanking: Hashable, Sendable {
    /// Why a candidate sits where it does.
    public enum Basis: Hashable, Sendable {
        /// Tied to the Wi-Fi network the Mac is on.
        case network(String)
        /// Every other verified server, in the user's list order.
        case listOrder
    }

    public struct Candidate: Hashable, Sendable {
        public var server: MusicAssistantServerConfiguration
        public var basis: Basis

        public init(server: MusicAssistantServerConfiguration, basis: Basis) {
            self.server = server
            self.basis = basis
        }
    }

    /// One probe's result. Only `.reachable` (it answered with its own stored `server_id`) can win.
    public enum Outcome: Hashable, Sendable { case reachable, unreachable, timedOut, mismatch, schemaUnsupported }

    public enum Decision: Hashable, Sendable {
        /// A higher-ranked probe is still running.
        case undecided
        case chosen(Candidate)
        /// Every candidate has an outcome and none is reachable (or there were no candidates).
        case none
    }

    public static let noneReachableText = "No Music Assistant server reachable"
    public static let noVerifiedServerText = "No Music Assistant server tested yet"
    public static let notCheckedText = "Not checked yet"
    public static let checkingText = "Finding a server\u{2026}"

    /// Verified servers only. Those whose `networks` contain `ssid` (exact match after trimming; SSIDs are
    /// case-sensitive) first, in list order, then every other one in list order.
    public static func candidates(_ servers: [MusicAssistantServerConfiguration], ssid: String?) -> [Candidate] {
        let verified = servers.filter(\.isVerified)
        let current = ssid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.isEmpty else { return verified.map { Candidate(server: $0, basis: .listOrder) } }
        func tied(_ server: MusicAssistantServerConfiguration) -> Bool {
            server.networks.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == current }
        }
        return verified.filter(tied).map { Candidate(server: $0, basis: .network(current)) }
            + verified.filter { !tied($0) }.map { Candidate(server: $0, basis: .listOrder) }
    }

    /// The first candidate in order whose outcome is `.reachable`, but only once every candidate ranked above it has
    /// an outcome. A missing outcome means "still probing".
    public static func decide(_ candidates: [Candidate], outcomes: [UUID: Outcome]) -> Decision {
        for candidate in candidates {
            switch outcomes[candidate.server.id] {
            case nil: return .undecided
            case .reachable: return .chosen(candidate)
            default: continue
            }
        }
        return .none
    }

    /// For the UI only: it holds names and network names, so it is never logged.
    public static func reason(for candidate: Candidate) -> String {
        switch candidate.basis {
        case .network(let ssid): return "\(candidate.server.displayName) \u{2014} on network \(ssid)"
        case .listOrder:
            return isTailscale(candidate.server.address.baseURL)
                ? "\(candidate.server.displayName) \u{2014} via Tailscale"
                : "\(candidate.server.displayName) \u{2014} first reachable"
        }
    }

    /// The Library window's label for the chosen server (#0124): its real name, only when there is more than one
    /// server to tell apart. Never the host or the selection reason. UI only, never logged.
    public static func libraryLabel(for server: MusicAssistantServerConfiguration?, serverCount: Int) -> String? {
        guard let server, serverCount > 1, !MusicAssistantServerConfiguration.isGenericName(server.name) else { return nil }
        return server.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The UI text for a decision; `.undecided` has none.
    public static func reason(for decision: Decision, hasCandidates: Bool) -> String? {
        switch decision {
        case .undecided: return nil
        case .chosen(let candidate): return reason(for: candidate)
        case .none: return hasCandidates ? noneReachableText : noVerifiedServerText
        }
    }

    /// A Tailscale address: a MagicDNS `*.ts.net` name, a CGNAT `100.64.0.0/10` IPv4 address, or Tailscale's
    /// `fd7a:115c:a1e0::/48` IPv6 range.
    public static func isTailscale(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".ts.net") || host.hasSuffix(".ts.net.") { return true }
        if host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, let first = Int(octets[0]), let second = Int(octets[1]),
            octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false })
        else { return false }
        return first == 100 && (64...127).contains(second)
    }
}
