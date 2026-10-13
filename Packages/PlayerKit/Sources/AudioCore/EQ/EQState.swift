import Foundation

/// Centre frequencies and bandwidths of the ten Winamp equalizer bands.
public enum EQBands {
    /// Hz.
    public static let frequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    /// Octaves. The top three bands sit 0.2 octave apart, so they are narrower.
    public static let bandwidths: [Float] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.5, 0.5, 0.5]
}

/// Equalizer settings the UI binds to and persists. Gains and preamp are always within `gainRange`
/// and `gains` always has `bandCount` entries.
public struct EQState: Codable, Equatable, Sendable {
    public static let bandCount = 10
    /// dB, Winamp's slider range.
    public static let gainRange: ClosedRange<Float> = -12...12

    /// Winamp "ON". When false the whole unit (bands and preamp) is bypassed.
    public var isEnabled: Bool
    public var preamp: Float { didSet { preamp = Self.clamped(preamp) } }
    public var gains: [Float] { didSet { gains = Self.normalized(gains) } }

    // `didSet` does not run inside initializers, so normalize explicitly.
    public init(isEnabled: Bool = true, preamp: Float = 0, gains: [Float] = Array(repeating: 0, count: 10)) {
        self.isEnabled = isEnabled
        self.preamp = Self.clamped(preamp)
        self.gains = Self.normalized(gains)
    }

    public static let flat = EQState()

    /// Convenience for `Binding($eq[band: i])`. Out-of-range indices read 0 and ignore writes.
    public subscript(band i: Int) -> Float {
        get { gains.indices.contains(i) ? gains[i] : 0 }
        set { if gains.indices.contains(i) { gains[i] = newValue } }
    }

    /// Copies the preset's preamp and gains; keeps `isEnabled` (loading a preset does not toggle ON).
    public func applying(_ preset: EQPreset) -> EQState {
        EQState(isEnabled: isEnabled, preamp: preset.preamp, gains: preset.gains)
    }

    static func clamped(_ value: Float) -> Float {
        guard !value.isNaN else { return 0 }
        return min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }

    static func normalized(_ values: [Float]) -> [Float] {
        var result = Array(values.prefix(bandCount)).map(clamped)
        while result.count < bandCount { result.append(0) }
        return result
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, preamp, gains }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            preamp: try c.decodeIfPresent(Float.self, forKey: .preamp) ?? 0,
            gains: try c.decodeIfPresent([Float].self, forKey: .gains) ?? []
        )
    }
}
