import Foundation

public enum Check: String, CaseIterable, Sendable {
    case pickerMultiSelect
    case longFormPlistHonored
    case movesOffMac
    case systemAudioStaysLocal
    case twoInSync
    case requestedAhead
    case survivesWifiOff
    case remoteCommands
    case tapTiming
    case clockIncludesLatency
    case volumeMapping
    case transport

    public var title: String {
        switch self {
        case .pickerMultiSelect: "Picker lists HomePods, multi-select"
        case .longFormPlistHonored: "Long-form plist key honored"
        case .movesOffMac: "Moves off the Mac with one HomePod"
        case .systemAudioStaysLocal: "Other system audio stays local"
        case .twoInSync: "Two HomePods in sync"
        case .requestedAhead: "Requested ahead, local vs AirPlay"
        case .survivesWifiOff: "Survives 10 s Wi-Fi off"
        case .remoteCommands: "Remote commands reach MPRemoteCommandCenter"
        case .tapTiming: "Tap timing vs audible output"
        case .clockIncludesLatency: "Clock includes AirPlay latency"
        case .volumeMapping: "Volume mapping"
        case .transport: "Pause, seek, next, quit"
        }
    }
}

public enum Cell: Equatable, Sendable {
    case untested, yes, no, na
    case value(String)

    public var text: String {
        switch self {
        case .untested: "untested"
        case .yes: "yes"
        case .no: "no"
        case .na: "n/a"
        case .value(let s): s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
        }
    }
}

/// The acceptance matrix as data; `markdown()` renders the table `docs/airplay-spike-results.md` carries.
public struct ResultsSheet: Sendable {
    public private(set) var cells: [EngineKind: [Check: Cell]]

    public init() {
        var all: [EngineKind: [Check: Cell]] = [:]
        for kind in EngineKind.allCases {
            all[kind] = Dictionary(uniqueKeysWithValues: Check.allCases.map { ($0, Cell.untested) })
        }
        cells = all
    }

    public subscript(kind: EngineKind, check: Check) -> Cell {
        get { cells[kind]?[check] ?? .untested }
        set { cells[kind, default: [:]][check] = newValue }
    }

    public func markdown() -> String {
        var lines: [String] = []
        lines.append("| Check | " + EngineKind.allCases.map(\.title).joined(separator: " | ") + " |")
        lines.append("|---|" + EngineKind.allCases.map { _ in "---" }.joined(separator: "|") + "|")
        for check in Check.allCases {
            let row = EngineKind.allCases.map { self[$0, check].text }.joined(separator: " | ")
            lines.append("| \(check.title) | \(row) |")
        }
        return lines.joined(separator: "\n")
    }
}
