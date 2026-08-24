import Foundation
import CoreAudio

public protocol Audibility: AnyObject {
    func prepare(_ device: OutputDevice)
    func restore(_ device: OutputDevice)
}

/// Makes a destination device actually audible, and puts back what it changed.
///
/// This is a correctness requirement, not a convenience. A device that is not the
/// system default keeps its own volume and mute state, which the keyboard volume keys
/// never touch. During development the first audible test failed entirely because the
/// destination was muted at the device level while reporting volume 1.000 — the audio
/// was routed perfectly and inaudibly.
public final class DestinationAudibility: Audibility {
    /// Prior mute value per device UID, stored on first observe (first-observation-wins).
    /// Subsequent prepare() calls on the same device before restore() do not overwrite this,
    /// so the true original state is preserved even if prepare() is called multiple times.
    private var priorMute: [String: UInt32] = [:]

    /// Injectable mute read function; defaults to Core Audio helper.
    private let readMuteFunc: (AudioObjectID) -> UInt32?
    /// Injectable mute write function; defaults to Core Audio helper.
    private let writeMuteFunc: (AudioObjectID, UInt32) -> Bool

    /// Initialize with default Core Audio helpers for production use.
    public init() {
        self.readMuteFunc = Self.readMute
        self.writeMuteFunc = Self.writeMute
    }

    /// Initialize with injectable mute read/write for testing.
    internal init(readMute: @escaping (AudioObjectID) -> UInt32?,
                  writeMute: @escaping (AudioObjectID, UInt32) -> Bool) {
        self.readMuteFunc = readMute
        self.writeMuteFunc = writeMute
    }

    public func prepare(_ device: OutputDevice) {
        // Record the mute state only on first observe; subsequent calls do not overwrite.
        if priorMute[device.uid] == nil, let existing = readMuteFunc(device.id) {
            priorMute[device.uid] = existing
        }
        _ = writeMuteFunc(device.id, 0)

        // Raise the volume only if it is inaudible; never lower an audible one.
        if let target = VolumeFloorRule.desiredVolume(current: Self.readVolume(device.id)) {
            _ = Self.writeVolume(device.id, target)
        }
    }

    /// Restores the prior *mute* state only. The prior volume is deliberately not
    /// restored: if the user adjusted the volume while listening, putting the old
    /// value back would silently undo their change.
    public func restore(_ device: OutputDevice) {
        if let prior = priorMute.removeValue(forKey: device.uid) {
            _ = writeMuteFunc(device.id, prior)
        }
    }

    // Devices expose volume and mute on either the main element or per channel;
    // try main first, then channels 1 and 2.
    public static func readVolume(_ device: AudioObjectID) -> Float? {
        if let v = CA.float32(device, kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: kAudioObjectPropertyElementMain) { return v }
        for channel in UInt32(1)...2 {
            if let v = CA.float32(device, kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioDevicePropertyScopeOutput,
                                  element: channel) { return v }
        }
        return nil
    }

    static func writeVolume(_ device: AudioObjectID, _ value: Float) -> Bool {
        var wrote = CA.setFloat32(device, kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioDevicePropertyScopeOutput,
                                  element: kAudioObjectPropertyElementMain, value)
        for channel in UInt32(1)...2 {
            if CA.setFloat32(device, kAudioDevicePropertyVolumeScalar,
                             scope: kAudioDevicePropertyScopeOutput,
                             element: channel, value) { wrote = true }
        }
        return wrote
    }

    public static func readMute(_ device: AudioObjectID) -> UInt32? {
        if let m = CA.uint32(device, kAudioDevicePropertyMute,
                             scope: kAudioDevicePropertyScopeOutput,
                             element: kAudioObjectPropertyElementMain) { return m }
        for channel in UInt32(1)...2 {
            if let m = CA.uint32(device, kAudioDevicePropertyMute,
                                 scope: kAudioDevicePropertyScopeOutput,
                                 element: channel) { return m }
        }
        return nil
    }

    static func writeMute(_ device: AudioObjectID, _ value: UInt32) -> Bool {
        var wrote = CA.setUInt32(device, kAudioDevicePropertyMute,
                                 scope: kAudioDevicePropertyScopeOutput,
                                 element: kAudioObjectPropertyElementMain, value)
        for channel in UInt32(1)...2 {
            if CA.setUInt32(device, kAudioDevicePropertyMute,
                            scope: kAudioDevicePropertyScopeOutput,
                            element: channel, value) { wrote = true }
        }
        return wrote
    }
}
