import Foundation
import CoreAudio

/// Verifies the whole routing path against real hardware using a process whose audio
/// we control, so a pass means "audio measurably flowed" rather than "no error was
/// returned". This exists because a tap outside a signed .app bundle returns perfectly
/// well-formed buffers of pure silence with no error at all — the single most
/// misleading failure mode in this project.
public enum SelfTest {
    public struct Outcome: Sendable {
        public let callbacks: Int
        public let peak: Float
        public let passed: Bool
        public let detail: String
    }

    public static func run(destination: OutputDevice, seconds: Double = 3) throws -> Outcome {
        let toneURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spotifyroute-selftest-\(getpid()).wav")
        try writeSineWAV(to: toneURL, seconds: seconds + 4, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [toneURL.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }

        // Wait for the player to actually hold an output stream.
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = player.processIdentifier
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var ready = false
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if AudioObjectGetPropertyData(CA.system, &addr,
                                          UInt32(MemoryLayout<pid_t>.size), &pid,
                                          &size, &processObject) == noErr,
               processObject != AudioObjectID(kAudioObjectUnknown),
               SpotifyProcess.isProducingOutput(processObject) {
                ready = true
                break
            }
        }
        guard ready else {
            throw RouteError.selfTestFailed("the test tone process never produced output")
        }

        let router = AudioRouter()
        try router.enable(destination: destination, processObject: processObject)
        defer { router.disable() }

        Thread.sleep(forTimeInterval: seconds)
        let (callbacks, peak) = router.statistics()

        if callbacks == 0 {
            return Outcome(callbacks: 0, peak: 0, passed: false,
                           detail: "no IOProc callbacks — the aggregate never ran")
        }
        // What's known versus assumed here: a zero peak with callbacks flowing means
        // the IOProc ran on schedule but the tap contributed no audio to the aggregate's
        // input — that part is measured, not inferred. That a missing audio-capture
        // permission is the cause is the most likely explanation for that signature in a
        // normal launch, but it is NOT something this project has been able to confirm by
        // observation: every attempt to demonstrate the bundled-vs-unbundled contrast in
        // the development environment passed on both sides, because every test process
        // was a descendant of an already-authorized ancestor app and inherited its grant
        // regardless of its own bundle identity or signature. So treat "permission
        // missing" as the leading hypothesis for this failure mode, not a verified fact —
        // if you're debugging a real silent-tap report, don't stop at re-granting Privacy
        // settings without also checking the wiring this comment sits next to.
        if peak <= 0.001 {
            return Outcome(callbacks: callbacks, peak: peak, passed: false,
                           detail: "callbacks ran but every sample was silent — this almost "
                                 + "always means the audio-capture permission is missing. "
                                 + "Confirm the binary is running from the signed .app "
                                 + "bundle and that Privacy settings allow audio recording.")
        }
        return Outcome(callbacks: callbacks, peak: peak, passed: true,
                       detail: "routed \(callbacks) buffers to \(destination.name), peak \(peak)")
    }

    /// Minimal 16-bit stereo PCM WAV writer — avoids depending on AVFoundation
    /// for what is a few dozen bytes of header.
    static func writeSineWAV(to url: URL, seconds: Double, amplitude: Double) throws {
        let sampleRate = 48_000
        let frequency = 440.0
        let frameCount = Int(Double(sampleRate) * seconds)
        var samples = Data(capacity: frameCount * 4)
        for n in 0..<frameCount {
            let value = Int16(amplitude * 32_767.0
                              * sin(2.0 * Double.pi * frequency * Double(n) / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }

        var file = Data()
        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }

        file.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + samples.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE32(16)                              // fmt chunk size
        appendLE16(1)                               // PCM
        appendLE16(2)                               // stereo
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 4))          // byte rate
        appendLE16(4)                               // block align
        appendLE16(16)                              // bits per sample
        file.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(samples.count))
        file.append(samples)

        try file.write(to: url, options: .atomic)
    }
}
