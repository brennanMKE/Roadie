import Foundation

/// A named preamp + ten band gains. Built-ins come from Winamp's shipped presets (via Webamp's
/// builtin.json), stored as Winamp slider values 1...64 and converted to dB.
public struct EQPreset: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    /// dB.
    public let preamp: Float
    /// Ten values, dB.
    public let gains: [Float]
    public var id: String { name }

    public init(name: String, preamp: Float, gains: [Float]) {
        self.name = name
        self.preamp = EQState.clamped(preamp)
        self.gains = EQState.normalized(gains)
    }

    /// Winamp/EQF slider value 1...64 (1 = -12 dB, 33 = 0 dB, 64 = +12 dB) to dB, rounded to 0.1.
    public static func decibels(fromWinampValue v: Int) -> Float {
        let clamped = Float(min(max(v, 1), 64))
        let db = clamped >= 33 ? (clamped - 33) * 12 / 31 : (clamped - 33) * 12 / 32
        return (db * 10).rounded() / 10
    }

    /// Inverse of `decibels(fromWinampValue:)`: 33 + round(db * 31/12) above 0 dB, 33 + round(db * 32/12) below; 1...64.
    public static func winampValue(fromDecibels db: Float) -> Int {
        let clamped = EQState.clamped(db)
        let steps = clamped >= 0 ? clamped * 31 / 12 : clamped * 32 / 12
        return min(max(33 + Int(steps.rounded()), 1), 64)
    }

    private init(name: String, winamp values: [Int]) {
        self.init(name: name, preamp: Self.decibels(fromWinampValue: 33), gains: values.map(Self.decibels(fromWinampValue:)))
    }

    /// Alphabetical after Flat, as in Winamp's preset dialog.
    public static let builtIn: [EQPreset] = [
        EQPreset(name: "Flat", winamp: [33, 33, 33, 33, 33, 33, 33, 33, 33, 33]),
        EQPreset(name: "Classical", winamp: [33, 33, 33, 33, 33, 33, 20, 20, 20, 16]),
        EQPreset(name: "Club", winamp: [33, 33, 38, 42, 42, 42, 38, 33, 33, 33]),
        EQPreset(name: "Dance", winamp: [48, 44, 36, 32, 32, 22, 20, 20, 32, 32]),
        EQPreset(name: "Full Bass", winamp: [48, 48, 48, 42, 35, 25, 18, 15, 14, 14]),
        EQPreset(name: "Full Bass & Treble", winamp: [44, 42, 33, 20, 24, 35, 46, 50, 52, 52]),
        EQPreset(name: "Full Treble", winamp: [16, 16, 16, 25, 37, 50, 58, 58, 58, 60]),
        EQPreset(name: "Laptop speakers/headphones", winamp: [40, 50, 41, 26, 28, 35, 40, 48, 53, 56]),
        EQPreset(name: "Large hall", winamp: [49, 49, 42, 42, 33, 24, 24, 24, 33, 33]),
        EQPreset(name: "Live", winamp: [24, 33, 39, 41, 42, 42, 39, 37, 37, 36]),
        EQPreset(name: "Party", winamp: [44, 44, 33, 33, 33, 33, 33, 33, 44, 44]),
        EQPreset(name: "Pop", winamp: [29, 40, 44, 45, 41, 30, 28, 28, 29, 29]),
        EQPreset(name: "Reggae", winamp: [33, 33, 31, 22, 33, 43, 43, 33, 33, 33]),
        EQPreset(name: "Rock", winamp: [45, 40, 23, 19, 26, 39, 47, 50, 50, 50]),
        EQPreset(name: "Ska", winamp: [28, 24, 25, 31, 39, 42, 47, 48, 50, 48]),
        EQPreset(name: "Soft", winamp: [40, 35, 30, 28, 30, 39, 46, 48, 50, 52]),
        EQPreset(name: "Soft Rock", winamp: [39, 39, 36, 31, 25, 23, 26, 31, 37, 47]),
        EQPreset(name: "Techno", winamp: [45, 42, 33, 23, 24, 33, 45, 48, 48, 47]),
    ]
}
