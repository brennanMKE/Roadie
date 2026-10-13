/// One snapshot of analyzer output for the visualizer.
public struct VisFrame: Sendable, Equatable {
    public static let columnCount = 75
    public static let scopeLength = 76

    /// `columnCount` values; 0 = floor (-60 dB), 1 = 0 dBFS.
    public var spectrum: [Float]
    /// `scopeLength` values in -1...1.
    public var scope: [Float]
    /// Total samples the tap had delivered when this frame was captured. Unchanged since the
    /// previous frame means no new audio arrived (draw decay / floor).
    public var sampleCount: Int

    public init(spectrum: [Float], scope: [Float], sampleCount: Int) {
        self.spectrum = spectrum
        self.scope = scope
        self.sampleCount = sampleCount
    }
}
