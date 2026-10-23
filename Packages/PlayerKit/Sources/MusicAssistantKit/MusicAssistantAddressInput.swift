import Foundation

/// Turns what the user typed into a base URL, and says whether App Transport Security lets the app use it.
///
/// ATS has `NSAllowsLocalNetworking` plus one exception domain, `ts.net` with subdomains, allowing insecure HTTP
/// loads (#0172); there is no `NSAllowsArbitraryLoads`. So plain `http`/`ws` works for the addresses ATS treats as
/// local (`.local` names, unqualified host names and IP addresses, Tailscale `100.x` included) and for Tailscale
/// MagicDNS `*.ts.net` names, whose traffic WireGuard encrypts. Every other address must use `https`/`wss`.
public enum MusicAssistantAddressInput {
    public enum Problem: Hashable, Sendable, Error {
        case empty, invalid, unsupportedScheme, credentialsNotAllowed
        /// `http://` to an address that is neither local nor a Tailscale MagicDNS name.
        case httpsRequired

        public var message: String {
            switch self {
            case .empty: "Enter the server's address."
            case .invalid: "That address isn't valid."
            case .unsupportedScheme: "Use an http or https address."
            case .credentialsNotAllowed: "Don't put a user name or password in the address."
            case .httpsRequired: "Use https for this address; plain http works only on the local network or Tailscale."
            }
        }
    }

    public static let defaultPort = 8095

    /// "host", "host:port", "[v6]:port", "http(s)://host[:port][/path]", "ws(s)://..." (mapped to http(s)).
    /// - No scheme: `http` for a local host or a `*.ts.net` name, `https` for any other.
    /// - `http` with no port gets 8095; `https` with no port stays on the default (443, a reverse proxy or `tailscale serve`).
    /// - Keeps a path (a reverse-proxy prefix); drops the query and fragment; trims whitespace; lowercases scheme and host.
    /// - `http` (or `ws`) to a host that is neither local nor `*.ts.net` is `.httpsRequired`.
    public static func parse(_ text: String) -> Result<URL, Problem> {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return .failure(.empty) }

        var scheme: String?
        if let range = rest.range(of: "://") {
            let name = rest[..<range.lowerBound].lowercased()
            guard !name.isEmpty, name.allSatisfy(\.isASCIILetter) else { return .failure(.invalid) }
            switch name {
            case "http", "ws": scheme = "http"
            case "https", "wss": scheme = "https"
            default: return .failure(.unsupportedScheme)
            }
            rest = String(rest[range.upperBound...])
        }
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
        guard !rest.contains(where: \.isWhitespace) else { return .failure(.invalid) }

        var authority = rest
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            path = String(rest[slash...])
        }
        if path == "/" { path = "" }
        if path.hasSuffix("/") { path.removeLast() }
        guard !authority.contains("@") else { return .failure(.credentialsNotAllowed) }

        var host: String
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return .failure(.invalid) }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { return .failure(.invalid) }
                portText = tail.dropFirst()
            }
            guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }), host.contains(":") else {
                return .failure(.invalid)
            }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return .failure(.invalid) }
            host = String(parts[0])
            if parts.count == 2 { portText = parts[1] }
            guard !host.isEmpty, !host.hasPrefix("."), !host.hasPrefix("-"),
                host.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" || $0 == "." || $0 == "_" })
            else { return .failure(.invalid) }
        }
        host = host.lowercased()

        var port: Int?
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy(\.isASCIIDigit), let value = Int(portText), (1...65535).contains(value)
            else { return .failure(.invalid) }
            port = value
        }

        let plainHTTPAllowed = isLocalHost(host) || isTailscaleMagicDNS(host)
        let resolved = scheme ?? (plainHTTPAllowed ? "http" : "https")
        if resolved == "http", !plainHTTPAllowed { return .failure(.httpsRequired) }
        if resolved == "http", port == nil { port = defaultPort }

        var string = resolved + "://" + (host.contains(":") ? "[\(host)]" : host)
        if let port { string += ":\(port)" }
        string += path
        guard let url = URL(string: string), url.host != nil else { return .failure(.invalid) }
        return .success(url)
    }

    /// The text to show for a stored URL; `parse` accepts it back unchanged.
    public static func displayText(_ url: URL) -> String { url.absoluteString }

    /// What ATS treats as local: an IP address, a `.local` name or an unqualified (single-label) name.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.isEmpty { return false }
        if host.contains(":") { return true }  // IPv6 literal
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && Int($0).map { $0 <= 255 } == true }) {
            return true  // IPv4 literal, Tailscale 100.x included
        }
        if host.hasSuffix(".local") { return true }
        return !host.contains(".")
    }

    /// A Tailscale MagicDNS name, `<label>.….ts.net`, which the ATS `ts.net` exception covers (#0172).
    /// Rejects `ts.net` itself, look-alikes such as `evil-ts.net`, and the trailing-dot form.
    static func isTailscaleMagicDNS(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let suffix = ".ts.net"
        guard host.hasSuffix(suffix) else { return false }
        let labels = host.dropLast(suffix.count).split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { !$0.isEmpty }
    }
}

/// How an address is carried, given the ATS rule above.
public enum MusicAssistantAddressSecurity: Hashable, Sendable {
    /// https (wss).
    case encrypted
    /// Plain http to a host ATS treats as local.
    case local
    /// Plain http to a Tailscale MagicDNS name: WireGuard encrypts it, and the ATS `ts.net` exception allows it.
    case tailnet
    /// Plain http to anything that is neither local nor `*.ts.net`. ATS blocks it (error -1022); Settings does not
    /// accept such an address.
    case requiresTLS

    public static func classify(_ url: URL) -> Self {
        switch url.scheme?.lowercased() {
        case "https", "wss": return .encrypted
        default:
            let host = url.host ?? ""
            if MusicAssistantAddressInput.isLocalHost(host) { return .local }
            return MusicAssistantAddressInput.isTailscaleMagicDNS(host) ? .tailnet : .requiresTLS
        }
    }
}

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
    var isASCIIDigit: Bool { isASCII && isNumber }
}
