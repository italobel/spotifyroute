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

    // Unique per AudioRouter instance, not per process (C-1/I-3 review): a later task
    // holds a live router in the menu-bar app, and a self-test invoked from that same
    // process would otherwise build a second AudioRouter requesting the SAME
    // per-pid aggregate UID — creation fails or aliases, and the self-test's teardown
    // would destroy an aggregate the main router still thinks it owns.
    private let instanceUID = UUID().uuidString

    public private(set) var activeDestinationUID: String?
    public var isActive: Bool { ioProcID != nil }

    public init() {}

    deinit {
        // A dropped router must not leak a system-wide tap/aggregate or leave its
        // IOProc running — the IOProc block below captures `metrics`, never `self`,
        // so nothing else ties the running callback to this object's lifetime.
        // disable() is idempotent, so calling it unconditionally here is safe even
        // if the router was never enabled or was already disabled.
        disable()
    }

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

        // The IOProc below reinterprets every sample as Float32 (I-7 review). That is
        // correct today because process taps report 32-bit float, packed — but if a
        // tap ever presented integer samples instead, reinterpreting them as float
        // would produce large-but-finite garbage values rather than a clean error,
        // and a route carrying that garbage would report a false PASS: exactly the
        // failure class this self-test exists to catch. Verify it once here, off the
        // real-time thread, rather than assuming it forever.
        var tapFormatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var tapFormat = AudioStreamBasicDescription()
        var tapFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CA.check(AudioObjectGetPropertyData(tapID, &tapFormatAddr, 0, nil,
                                                &tapFormatSize, &tapFormat),
                     "read tap format")
        // Checking only kAudioFormatFlagIsFloat is not what this guard's own error
        // message claims: a Float64 tap, or a non-packed Float32 tap, also sets that
        // flag and would sail through here, only to be misread by the IOProc's
        // `assumingMemoryBound(to: Float.self)` below — producing a non-zero peak and
        // a false PASS, exactly the failure class this guard exists to close. Also
        // require 32 bits per channel and the packed flag so the guard actually
        // verifies what it says it verifies.
        guard tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32,
              tapFormat.mFormatFlags & kAudioFormatFlagIsPacked != 0
        else {
            throw RouteError.coreAudio(
                "tap format is not 32-bit packed float (flags=\(tapFormat.mFormatFlags), " +
                "bitsPerChannel=\(tapFormat.mBitsPerChannel)) — the IOProc's sample " +
                "reinterpretation would be invalid", OSStatus(-1))
        }

        // Where the tap's buffer lands in the aggregate's IOProc input list (C-1
        // review). The aggregate places each sub-device's OWN native input buffers
        // ahead of the tap's buffer(s): a destination with no input channels of its
        // own (built-in speakers, a display's speakers) puts the tap at index 0, but
        // a destination that also has inputs (a RODECaster, Camo, Splashtop) puts its
        // own hardware/virtual input buffer(s) first and the tap after them. Assuming
        // index 0 unconditionally silently copies the destination's own input to its
        // own output instead of the tapped audio — on a RODECaster that is a
        // mic-to-speaker feedback path, and Spotify goes silent while still muted at
        // source. Computed once here, off the real-time thread, and captured by the
        // IOProc block below as a plain Int.
        // A failed property read must not silently become 0 (C-1's exact failure
        // mode): offset 0 is indistinguishable from "this destination has no input
        // buffers of its own" and would put the IOProc right back on the destination's
        // own microphone-to-output path the C-1 fix exists to avoid. The aggregate
        // path below already fails loudly on a bad read; this one must too.
        guard let tapInputOffset = Self.inputBufferCount(destination.id) else {
            throw RouteError.coreAudio(
                "could not read input buffer count for destination \(destination.uid)",
                OSStatus(-1))
        }

        // --- the aggregate: destination is clock master, tap is the input ---
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpotifyRoute",
            kAudioAggregateDeviceUIDKey: "com.italo.spotifyroute.aggregate.\(instanceUID)",
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

        // Verify the offset against the aggregate's actual input buffer count, once,
        // before the IOProc ever runs. A wrong assumption here must fail loudly
        // rather than silently route the wrong buffer for the life of the route.
        guard let aggregateInputBufferCount = Self.inputBufferCount(aggregateID) else {
            throw RouteError.coreAudio(
                "could not read input buffer count for the aggregate device", OSStatus(-1))
        }
        guard tapInputOffset < aggregateInputBufferCount else {
            throw RouteError.coreAudio(
                "tap input offset (\(tapInputOffset)) is not less than the aggregate's " +
                "input buffer count (\(aggregateInputBufferCount)) for destination " +
                "\(destination.uid) — the tap position assumption does not hold here",
                OSStatus(-1))
        }

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
            for i in 0..<outputs.count {
                // Bounds-checked rather than trusting tapInputOffset forever: a
                // shorter-than-expected input list (e.g. the destination dropping its
                // own input stream at runtime) must not index out of range.
                let inputIndex = tapInputOffset + i
                guard inputIndex < inputs.count else { continue }
                guard let source = inputs[inputIndex].mData, let dest = outputs[i].mData
                else { continue }
                let bytes = min(inputs[inputIndex].mDataByteSize, outputs[i].mDataByteSize)
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

    /// Number of input-SCOPE buffers a device presents in its
    /// `kAudioDevicePropertyStreamConfiguration` — a buffer count, not a channel
    /// count. This is what determines how many buffers an aggregate inserts ahead of
    /// its tap's buffer(s) in the IOProc's input list (see C-1 in `enableUnchecked`).
    /// `nil` on a failed property read — never 0. A silent fallback to 0 here is
    /// indistinguishable from a genuine "no input buffers" answer, and on the
    /// destination path that silently reintroduces the exact bug C-1 fixed: the tap
    /// offset lands on the destination's own input, copying its microphone to its own
    /// output. Callers must fail loudly on `nil` rather than treat it as 0.
    private static func inputBufferCount(_ device: AudioObjectID) -> Int? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr
        else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.count
    }
}

/// Abstracts the routing hardware so command semantics can be tested without it.
public protocol Routing: AnyObject {
    var isActive: Bool { get }
    var activeDestinationUID: String? { get }
    func enable(destination: OutputDevice, processObject: AudioObjectID) throws
    func disable()
}

extension AudioRouter: Routing {}
