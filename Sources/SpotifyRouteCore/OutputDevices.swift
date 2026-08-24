import Foundation
import CoreAudio

public struct OutputDevice: Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double

    public init(id: AudioObjectID, uid: String, name: String, sampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
    }
}

public enum OutputDevices {
    /// Every device with at least one output channel.
    public static func all() throws -> [OutputDevice] {
        try CA.objectIDs(CA.system, kAudioHardwarePropertyDevices).compactMap { id in
            guard CA.outputChannelCount(id) > 0,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  let name = CA.string(id, kAudioObjectPropertyName)
            else { return nil }
            // kAudioDevicePropertyNominalSampleRate is a Float64, not Float32 — using
            // the wrong width makes AudioObjectGetPropertyData fail on size, which
            // float32() would silently turn into nil (and this device into 0 Hz).
            let rate = CA.float64(id, kAudioDevicePropertyNominalSampleRate,
                                  scope: kAudioObjectPropertyScopeGlobal)
            return OutputDevice(id: id, uid: uid, name: name, sampleRate: rate ?? 0)
        }
    }

    /// Read ONLY so that a destination equal to the current default can be refused.
    /// The default device is never modified, and routing never depends on its identity.
    public static func currentDefaultUID() -> String? {
        guard let id = CA.uint32(CA.system, kAudioHardwarePropertyDefaultOutputDevice)
        else { return nil }
        return CA.string(AudioObjectID(id), kAudioDevicePropertyDeviceUID)
    }
}

public protocol DeviceListing {
    func allOutputDevices() throws -> [OutputDevice]
    func currentDefaultUID() -> String?
}

public struct LiveDeviceListing: DeviceListing {
    public init() {}
    public func allOutputDevices() throws -> [OutputDevice] { try OutputDevices.all() }
    public func currentDefaultUID() -> String? { OutputDevices.currentDefaultUID() }
}
