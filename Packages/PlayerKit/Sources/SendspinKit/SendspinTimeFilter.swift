import Foundation

/// Port of Sendspin/time-filter `cpp/sendspin_time_filter.cpp` (main 531e2707): a two-state Kalman filter on clock
/// offset and drift. No lock: callers own it (the session actor).
public struct SendspinTimeFilter: Sendable {
    public struct Config: Sendable {
        public var processStdDev: Double = 0
        public var driftProcessStdDev: Double = 1e-11
        public var forgetFactor: Double = 2
        public var adaptiveCutoff: Double = 3
        public var minSamples: Int = 100
        public var driftSignificanceThreshold: Double = 2
        public var maxErrorScale: Double = 0.5
        public init() {}
    }

    private let processVariance: Double
    private let driftProcessVariance: Double
    private let forgetVarianceFactor: Double
    private let adaptiveForgettingCutoff: Double
    private let driftSignificanceThresholdSquared: Double
    private let maxErrorScale: Double
    private let minSamplesForForgetting: Int

    private var lastUpdate: Int64 = 0
    private var offset: Double = 0
    private var drift: Double = 0
    private var offsetCovariance: Double = .infinity
    private var offsetDriftCovariance: Double = 0
    private var driftCovariance: Double = 0
    private var useDrift = false
    private var count = 0

    public init(config: Config = Config()) {
        processVariance = config.processStdDev * config.processStdDev
        driftProcessVariance = config.driftProcessStdDev * config.driftProcessStdDev
        forgetVarianceFactor = config.forgetFactor * config.forgetFactor
        adaptiveForgettingCutoff = config.adaptiveCutoff
        driftSignificanceThresholdSquared = config.driftSignificanceThreshold * config.driftSignificanceThreshold
        maxErrorScale = config.maxErrorScale
        minSamplesForForgetting = config.minSamples
    }

    /// Client time (µs) of the last accepted sample; 0 before any.
    public var lastUpdateMicros: Int64 { lastUpdate }

    /// Accepted samples so far (stops counting at `minSamples`, as in the C++).
    public var sampleCount: Int { count }

    /// Rounded standard deviation of the offset estimate (µs); `Int64.max` before the first sample.
    public var error: Int64 {
        guard offsetCovariance.isFinite else { return .max }
        return Int64(sqrt(offsetCovariance).rounded())
    }

    public mutating func update(measurement: Int64, maxError: Int64, timeAdded: Int64) {
        if timeAdded <= lastUpdate { return }
        if maxError <= 0 { return }

        let dt = Double(timeAdded - lastUpdate)
        let dtSquared = dt * dt
        lastUpdate = timeAdded

        let updateStdDev = Double(maxError) * maxErrorScale
        let measurementVariance = updateStdDev * updateStdDev
        let measured = Double(measurement)

        if count <= 0 {
            count += 1
            offset = measured
            offsetCovariance = measurementVariance
            drift = 0
            return
        }

        if count == 1 {
            count += 1
            drift = (measured - offset) / dt
            offset = measured
            driftCovariance = (offsetCovariance + measurementVariance) / dtSquared
            offsetCovariance = measurementVariance
            return
        }

        let predictedOffset = offset + drift * dt
        var newDriftCovariance = driftCovariance + dt * driftProcessVariance
        var newOffsetDriftCovariance = offsetDriftCovariance + driftCovariance * dt
        var newOffsetCovariance = offsetCovariance + 2 * offsetDriftCovariance * dt + driftCovariance * dtSquared
            + dt * processVariance

        let residual = measured - predictedOffset
        let maxResidualCutoff = Double(maxError) * adaptiveForgettingCutoff

        if count < minSamplesForForgetting {
            count += 1
        } else if abs(residual) > maxResidualCutoff {
            newDriftCovariance *= forgetVarianceFactor
            newOffsetDriftCovariance *= forgetVarianceFactor
            newOffsetCovariance *= forgetVarianceFactor
        }

        let uncertainty = 1.0 / (newOffsetCovariance + measurementVariance)
        let offsetGain = newOffsetCovariance * uncertainty
        let driftGain = newOffsetDriftCovariance * uncertainty

        offset = predictedOffset + offsetGain * residual
        drift += driftGain * residual

        driftCovariance = newDriftCovariance - driftGain * newOffsetDriftCovariance
        offsetDriftCovariance = newOffsetDriftCovariance - driftGain * newOffsetCovariance
        offsetCovariance = newOffsetCovariance - offsetGain * newOffsetCovariance

        useDrift = drift * drift > driftSignificanceThresholdSquared * driftCovariance
    }

    public func computeServerTime(_ client: Int64) -> Int64 {
        let dt = Double(client - lastUpdate)
        let effectiveDrift = useDrift ? drift : 0
        return client + Int64((offset + effectiveDrift * dt).rounded())
    }

    public func computeClientTime(_ server: Int64) -> Int64 {
        let effectiveDrift = useDrift ? drift : 0
        return Int64(((Double(server) - offset + effectiveDrift * Double(lastUpdate)) / (1 + effectiveDrift)).rounded())
    }

    public mutating func reset() {
        count = 0
        offset = 0
        drift = 0
        offsetCovariance = .infinity
        offsetDriftCovariance = 0
        driftCovariance = 0
        lastUpdate = 0
        useDrift = false
    }
}
