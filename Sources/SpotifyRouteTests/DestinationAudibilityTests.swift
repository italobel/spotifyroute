import Foundation
import CoreAudio
@testable import SpotifyRouteCore

func runDestinationAudibilityTests() -> Int {
    let r = TestRunner("DestinationAudibility")

    // Track mute reads and writes for testing
    var muteState: [AudioObjectID: UInt32] = [:]
    var muteWriteLog: [(AudioObjectID, UInt32)] = []

    let mockReadMute: (AudioObjectID) -> UInt32? = { id in
        muteState[id]
    }

    let mockWriteMute: (AudioObjectID, UInt32) -> Bool = { id, value in
        muteState[id] = value
        muteWriteLog.append((id, value))
        return true
    }

    // Track volume reads and writes for testing
    var volumeState: [AudioObjectID: Float] = [:]
    var volumeWriteLog: [(AudioObjectID, Float)] = []

    let mockReadVolume: (AudioObjectID) -> Float? = { id in
        volumeState[id]
    }

    let mockWriteVolume: (AudioObjectID, Float) -> Bool = { id, value in
        volumeWriteLog.append((id, value))
        return true
    }

    // Helper to create test devices with distinct IDs
    let device1 = OutputDevice(id: 1, uid: "device1", name: "Device 1", sampleRate: 48000)
    let device2 = OutputDevice(id: 2, uid: "device2", name: "Device 2", sampleRate: 48000)

    r.test("prepare once on a muted device, then restore → device restored to muted") {
        // Reset state
        muteState = [1: 1]  // device1 is muted
        volumeState = [:]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)
        audibility.prepare(device1)
        audibility.restore(device1)

        // Verify: should have written unmute (0) then restore to mute (1)
        try expectEqual(muteWriteLog.count, 2)
        try expectEqual(muteWriteLog[0].0, AudioObjectID(1))
        try expectEqual(muteWriteLog[0].1, UInt32(0))  // unmute
        try expectEqual(muteWriteLog[1].0, AudioObjectID(1))
        try expectEqual(muteWriteLog[1].1, UInt32(1))  // restore to muted
    }

    r.test("prepare TWICE then restore ONCE → device still restored to original muted state") {
        // This is the regression test: second prepare() must not clobber the stored state
        muteState = [1: 1]  // device1 is muted
        volumeState = [:]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)

        // First prepare: reads muted (1), stores it, writes unmute (0)
        audibility.prepare(device1)
        try expectEqual(muteWriteLog.count, 1)
        try expectEqual(muteWriteLog[0].1, UInt32(0))  // first prepare unmutes

        // Second prepare: reads unmuted (0), but must NOT overwrite stored state
        // Should still write unmute (0) again
        audibility.prepare(device1)
        try expectEqual(muteWriteLog.count, 2)
        try expectEqual(muteWriteLog[1].1, UInt32(0))  // second prepare also unmutes

        // Now restore: should restore to the ORIGINAL muted state (1), not the current (0)
        audibility.restore(device1)
        try expectEqual(muteWriteLog.count, 3)
        try expectEqual(muteWriteLog[2].1, UInt32(1))  // restored to original muted state
    }

    r.test("restore with no preceding prepare → no write attempted") {
        muteWriteLog = []
        volumeWriteLog = []
        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)

        // Call restore without prepare
        audibility.restore(device1)

        // Should have attempted no writes (mute or volume)
        try expectEqual(muteWriteLog.count, 0)
        try expectEqual(volumeWriteLog.count, 0)
    }

    r.test("two different devices tracked independently") {
        muteState = [1: 1, 2: 0]  // device1 muted, device2 unmuted
        volumeState = [:]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)

        // Prepare device1 (muted)
        audibility.prepare(device1)
        try expectEqual(muteWriteLog.count, 1)
        try expectEqual(muteWriteLog[0].0, AudioObjectID(1))
        try expectEqual(muteWriteLog[0].1, UInt32(0))

        // Prepare device2 (unmuted)
        audibility.prepare(device2)
        try expectEqual(muteWriteLog.count, 2)
        try expectEqual(muteWriteLog[1].0, AudioObjectID(2))
        try expectEqual(muteWriteLog[1].1, UInt32(0))

        // Restore device1: should restore to muted (1)
        audibility.restore(device1)
        try expectEqual(muteWriteLog.count, 3)
        try expectEqual(muteWriteLog[2].0, AudioObjectID(1))
        try expectEqual(muteWriteLog[2].1, UInt32(1))

        // Restore device2: should restore to unmuted (0)
        audibility.restore(device2)
        try expectEqual(muteWriteLog.count, 4)
        try expectEqual(muteWriteLog[3].0, AudioObjectID(2))
        try expectEqual(muteWriteLog[3].1, UInt32(0))
    }

    r.test("volume below floor → prepare writes raised volume on first call") {
        // With volume 0.05 (below 0.2 floor), prepare() must write 0.5
        muteState = [1: 0]
        volumeState = [1: 0.05]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)
        audibility.prepare(device1)

        // Must have written volume 0.5
        try expectEqual(volumeWriteLog.count, 1)
        try expectEqual(volumeWriteLog[0].0, AudioObjectID(1))
        try expectEqual(volumeWriteLog[0].1, 0.5)
    }

    r.test("volume below floor → prepare writes raised volume on BOTH calls") {
        // Regression guard: second prepare() must also raise volume
        muteState = [1: 0]
        volumeState = [1: 0.05]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)
        audibility.prepare(device1)
        try expectEqual(volumeWriteLog.count, 1)
        try expectEqual(volumeWriteLog[0].1, 0.5)

        audibility.prepare(device1)
        try expectEqual(volumeWriteLog.count, 2)
        try expectEqual(volumeWriteLog[1].1, 0.5)
    }

    r.test("volume above floor → prepare writes NO volume") {
        // With volume 0.8 (above 0.2 floor), prepare() must NOT write volume
        muteState = [1: 0]
        volumeState = [1: 0.8]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)
        audibility.prepare(device1)

        // Must NOT have written any volume (decision logic must suppress the write)
        try expectEqual(volumeWriteLog.count, 0)
    }

    r.test("restore must NOT write volume, only mute") {
        // restore() must never touch volume, even if volume was modified by prepare()
        muteState = [1: 1]
        volumeState = [1: 0.05]
        muteWriteLog = []
        volumeWriteLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute,
                                                 readVolume: mockReadVolume, writeVolume: mockWriteVolume)
        audibility.prepare(device1)
        muteWriteLog = []   // clear mute writes from prepare
        volumeWriteLog = [] // clear volume writes from prepare
        audibility.restore(device1)

        // restore() must NOT write volume
        try expectEqual(volumeWriteLog.count, 0)
        // restore() MUST write mute
        try expectEqual(muteWriteLog.count, 1)
        try expectEqual(muteWriteLog[0].1, UInt32(1))  // restore to muted
    }

    return r.summarise()
}
