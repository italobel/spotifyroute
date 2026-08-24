/// Decides whether a destination device's volume needs raising to be audible.
///
/// Exists because an output device that is not the system default keeps its own
/// volume and mute state, untouched by the keyboard volume keys. During development
/// the first audible test failed purely because the destination was muted at the
/// device level while reporting volume 1.000.
public enum VolumeFloorRule {
    /// Below this, the device is considered inaudible.
    public static let floor: Float = 0.2
    /// What we raise an inaudible device to.
    public static let target: Float = 0.5

    /// - Parameter current: the device's current scalar volume, or nil if unreadable.
    /// - Returns: the volume to set, or nil to leave the volume untouched.
    public static func desiredVolume(current: Float?) -> Float? {
        guard let current else { return target }
        return current < floor ? target : nil
    }
}
