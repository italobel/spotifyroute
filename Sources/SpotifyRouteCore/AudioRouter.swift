import Foundation
import CoreAudio
import AudioToolbox

/// Owns every Core Audio object involved in a route: the process tap, the private
/// aggregate device wrapping the destination, and the IOProc copying one to the other.
///
/// The recipe here was established by measurement and should not be altered without
/// re-measuring. In particular `.mutedWhenTapped` is what *moves* the app's audio
/// rather than duplicating it, and the destination must be the aggregate's main
/// sub-device so that both ends share one clock domain and need no resampling.
public final class AudioRouter {
    /// Callback-shared state, guarded by a lock rather than actor isolation because
    /// the IOProc runs on a Core Audio real-time thread.
    private final class Metrics {
        private let lock = NSLock()
        private var callbacks = 0
        private var peak: Float = 0
        func record(peak newPeak: Float) {
            lock.lock(); callbacks += 1; peak = max(peak, newPeak); lock.unlock()
        }
        func snapshot() -> (Int, Float) {
            lock.lock(); defer { peak = 0; lock.unlock() }; return (callbacks, peak)
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var metrics = Metrics()

    public private(set) var activeDestinationUID: String?
    public var isActive: Bool { ioProcID != nil }

    public init() {}

    public func enable(destination: OutputDevice, processObject: AudioObjectID) throws {
        if isActive {
            if activeDestinationUID == destination.uid { return }  // idempotent
            disable()                                              // destination changed
        }

        // Every throwing step below allocates a system-wide Core Audio object (a
        // process tap and/or an aggregate device). If any step fails partway through,
        // the catch below tears down everything allocated so far via disable() — which
        // is safe to call at any point, including on a completely fresh router — rather
        // than leaving an orphaned tap or aggregate device behind.
        do {
            try enableUnchecked(destination: destination, processObject: processObject)
        } catch {
            disable()
            throw error
        }
    }

    private func enableUnchecked(destination: OutputDevice, processObject: AudioObjectID) throws {
        // --- the tap ---
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "SpotifyRoute"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            // Opportunistic: lets the OS reattach the tap when Spotify relaunches.
            // Never relied upon, since the supported floor is 14.2.
            description.isProcessRestoreEnabled = true
        }

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateProcessTap(description, &newTap),
                     "AudioHardwareCreateProcessTap")
        tapID = newTap

        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            throw RouteError.coreAudio("read tap UID", OSStatus(-1))
        }

        // --- the aggregate: destination is clock master, tap is the input ---
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpotifyRoute",
            kAudioAggregateDeviceUIDKey: "com.italo.spotifyroute.aggregate.\(getpid())",
            kAudioAggregateDeviceMainSubDeviceKey: destination.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: destination.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &newAggregate),
                     "AudioHardwareCreateAggregateDevice")
        aggregateID = newAggregate

        // --- the IOProc ---
        let metrics = Metrics()
        self.metrics = metrics
        var newProc: AudioDeviceIOProcID?
        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            // Zero every output buffer first, so any buffer the tap does not fill
            // emits silence rather than whatever was left in it.
            for i in 0..<outputs.count {
                if let data = outputs[i].mData {
                    memset(data, 0, Int(outputs[i].mDataByteSize))
                }
            }
            var peak: Float = 0
            for i in 0..<min(inputs.count, outputs.count) {
                guard let source = inputs[i].mData, let dest = outputs[i].mData else { continue }
                let bytes = min(inputs[i].mDataByteSize, outputs[i].mDataByteSize)
                memcpy(dest, source, Int(bytes))
                let sampleCount = Int(bytes) / MemoryLayout<Float>.size
                let samples = source.assumingMemoryBound(to: Float.self)
                for s in 0..<sampleCount { peak = max(peak, abs(samples[s])) }
            }
            metrics.record(peak: peak)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = newProc

        try CA.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        activeDestinationUID = destination.uid
    }

    /// Safe to call at any time, including part-way through a failed enable().
    public func disable() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        activeDestinationUID = nil
    }

    public func statistics() -> (callbacks: Int, peak: Float) {
        let (callbacks, peak) = metrics.snapshot()
        return (callbacks, peak)
    }
}
