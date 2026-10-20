import AVFoundation
import CoreAudio
import os

private let log = Logger(subsystem: "com.brennanmke.SkinAmp", category: "AudioOutput")

/// Where the system default output device comes from, and how the engine is bound to it.
/// The real one talks to CoreAudio; tests inject a manual one. Nothing here ever changes the default.
public protocol OutputDeviceProvider: Sendable {
    /// The system default output device now; nil when there is none.
    func defaultOutputDevice() -> AudioDeviceID?
    /// One element per change of the default, carrying the new id. Installing the listener is lazy
    /// (first iteration); cancelling the consuming task removes it (`onTermination`).
    func defaultOutputDeviceChanges() -> AsyncStream<AudioDeviceID>
    /// Device the output node is bound to now (nil if none, e.g. manual rendering mode).
    @MainActor func boundDevice(of outputNode: AVAudioOutputNode) -> AudioDeviceID?
    /// Binds the output node to `device`. Called only while the engine is stopped. Must be a no-op
    /// when the node's engine is in manual rendering mode (no device behind it).
    @MainActor func bind(_ device: AudioDeviceID, to outputNode: AVAudioOutputNode) throws
    /// For logs and the hand test: device name, transport type (built-in, AirPlay, USB...), nominal rate.
    func describe(_ device: AudioDeviceID) -> OutputDeviceDescription?
}

public struct OutputDeviceDescription: Sendable, Equatable {
    public let id: AudioDeviceID
    public let name: String
    /// `kAudioDevicePropertyTransportType` as text ("AirPlay", "Built-in", ...).
    public let transport: String
    public let nominalSampleRate: Double
    /// Output latency plus safety offset (output scope), in seconds; 0 when unknown.
    public let latencySeconds: Double

    public init(
        id: AudioDeviceID, name: String, transport: String, nominalSampleRate: Double, latencySeconds: Double = 0
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.nominalSampleRate = nominalSampleRate
        self.latencySeconds = latencySeconds
    }
}

/// Holds the CoreAudio listener block so the stream's termination handler can remove it.
private final class DefaultOutputListener: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.brennanmke.SkinAmp.AudioOutput")
    var block: AudioObjectPropertyListenerBlock?
}

/// CoreAudio implementation.
public struct SystemOutputDeviceProvider: OutputDeviceProvider {
    public init() {}

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    public func defaultOutputDevice() -> AudioDeviceID? {
        var address = Self.defaultOutputAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    public func defaultOutputDeviceChanges() -> AsyncStream<AudioDeviceID> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let listener = DefaultOutputListener()
            let provider = self
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                // The element is the device itself, not just "something changed".
                if let device = provider.defaultOutputDevice() { continuation.yield(device) }
            }
            listener.block = block
            var address = Self.defaultOutputAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listener.queue, block)
            if status != noErr {
                log.error("could not listen for default output changes: \(status, privacy: .public)")
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                var address = Self.defaultOutputAddress
                if let block = listener.block {
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject), &address, listener.queue, block)
                }
                listener.block = nil
            }
        }
    }

    @MainActor
    public func boundDevice(of outputNode: AVAudioOutputNode) -> AudioDeviceID? {
        if outputNode.engine?.isInManualRenderingMode == true { return nil }
        let device = outputNode.auAudioUnit.deviceID
        return device == AudioDeviceID(kAudioObjectUnknown) ? nil : device
    }

    @MainActor
    public func bind(_ device: AudioDeviceID, to outputNode: AVAudioOutputNode) throws {
        guard outputNode.engine?.isInManualRenderingMode != true else { return }
        if outputNode.auAudioUnit.deviceID == device { return }
        do {
            try outputNode.auAudioUnit.setDeviceID(device)
            return
        } catch {
            log.error("setDeviceID failed (\(error.localizedDescription, privacy: .public)); trying the AudioUnit property")
            logOutputUnit(outputNode)
            guard let unit = outputNode.audioUnit else {
                throw AudioCoreError.outputDevice(underlying: error)
            }
            var id = device
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw AudioCoreError.outputDevice(underlying: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
            }
        }
    }

    private func logOutputUnit(_ outputNode: AVAudioOutputNode) {
        guard let unit = outputNode.audioUnit else { return }
        let component = AudioComponentInstanceGetComponent(unit)
        var description = AudioComponentDescription()
        AudioComponentGetDescription(component, &description)
        log.error("output unit type \(description.componentType, privacy: .public) subtype \(description.componentSubType, privacy: .public)")
    }

    public func describe(_ device: AudioDeviceID) -> OutputDeviceDescription? {
        let object = AudioObjectID(device)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &nameAddress, 0, nil, &size, &name) == noErr,
              let name else { return nil }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(object, &transportAddress, 0, nil, &size, &transport)

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(object, &rateAddress, 0, nil, &size, &rate)

        var latencyFrames: UInt32 = 0
        for selector in [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var frames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &frames) == noErr { latencyFrames += frames }
        }

        return OutputDeviceDescription(
            id: device, name: name.takeRetainedValue() as String, transport: Self.transportName(transport),
            nominalSampleRate: rate, latencySeconds: rate > 0 ? Double(latencyFrames) / rate : 0)
    }

    static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        default:
            String(decoding: [24, 16, 8, 0].map { UInt8((type >> $0) & 0xFF) }, as: UTF8.self)
        }
    }
}
