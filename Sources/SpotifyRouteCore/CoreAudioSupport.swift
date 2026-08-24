import Foundation
import CoreAudio

public enum RouteError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case deviceNotFound(String)
    case spotifyNotRunning
    case destinationIsDefault(String)
    case noDestinationChosen
    case selfTestFailed(String)

    public var description: String {
        switch self {
        case .coreAudio(let what, let status):
            return "\(what) failed: OSStatus \(status) \(fourCC(status))"
        case .deviceNotFound(let uid):
            return "no output device with UID \(uid)"
        case .spotifyNotRunning:
            return "Spotify is not running"
        case .destinationIsDefault(let name):
            return "\(name) is already the system default; routing it to itself only adds latency"
        case .noDestinationChosen:
            return "no destination device chosen — run 'spotroute list' then 'spotroute use <uid>'"
        case .selfTestFailed(let detail):
            return "self-test failed: \(detail)"
        }
    }
}

/// Renders an OSStatus as its four-character code when printable. Core Audio errors
/// are almost always FourCCs and are unreadable as signed decimals.
public func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                 UInt8((value >> 8) & 0xff),  UInt8(value & 0xff)]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }),
          let text = String(bytes: bytes, encoding: .ascii) else { return "" }
    return "'\(text)'"
}

public enum CA {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw RouteError.coreAudio(what, status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func string(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    public static func uint32(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> UInt32? {
        var addr = address(selector, scope, element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    public static func float32(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> Float? {
        var addr = address(selector, scope, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    /// Like `float32`, but for properties that are natively Float64 — notably
    /// kAudioDevicePropertyNominalSampleRate. Requesting the wrong width makes
    /// AudioObjectGetPropertyData fail with a bad-property-size error, which this
    /// layer otherwise silently maps to `nil`.
    public static func float64(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> Double? {
        var addr = address(selector, scope, element)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    public static func setFloat32(_ object: AudioObjectID,
                                  _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope,
                                  element: AudioObjectPropertyElement,
                                  _ newValue: Float) -> Bool {
        var addr = address(selector, scope, element)
        var value = Float32(newValue)
        return AudioObjectSetPropertyData(object, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    public static func setUInt32(_ object: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope,
                                 element: AudioObjectPropertyElement,
                                 _ newValue: UInt32) -> Bool {
        var addr = address(selector, scope, element)
        var value = newValue
        return AudioObjectSetPropertyData(object, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    public static func objectIDs(_ object: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size),
                  "get size of \(selector)")
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids),
                  "get \(selector)")
        return ids
    }

    /// Number of output channels across all output streams; 0 means input-only.
    public static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return (0..<list.count).reduce(0) { $0 + Int(list[$1].mNumberChannels) }
    }
}
