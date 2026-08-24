import Foundation
import AppKit
import CoreAudio

public enum SpotifyProcess {
    public static let bundleID = "com.spotify.client"

    public static func processObject() throws -> AudioObjectID {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier > 0 })
        else { throw RouteError.spotifyNotRunning }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = app.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try CA.check(AudioObjectGetPropertyData(CA.system, &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object),
                     "translate Spotify pid \(pid) to process object")
        guard object != AudioObjectID(kAudioObjectUnknown) else {
            throw RouteError.spotifyNotRunning
        }
        return object
    }

    /// True while the process holds an active output stream. A fully paused Spotify
    /// releases its stream, and the tap then legitimately produces no callbacks.
    public static func isProducingOutput(_ object: AudioObjectID) -> Bool {
        CA.uint32(object, kAudioProcessPropertyIsRunningOutput) == 1
    }
}
