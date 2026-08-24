import Foundation
import CoreAudio
@testable import SpotifyRouteCore

func runDestinationAudibilityTests() -> Int {
    let r = TestRunner("DestinationAudibility")

    // Track mute reads and writes for testing
    var muteState: [AudioObjectID: UInt32] = [:]
    var writeLog: [(AudioObjectID, UInt32)] = []

    let mockReadMute: (AudioObjectID) -> UInt32? = { id in
        muteState[id]
    }

    let mockWriteMute: (AudioObjectID, UInt32) -> Bool = { id, value in
        muteState[id] = value
        writeLog.append((id, value))
        return true
    }

    // Helper to create test devices with distinct IDs
    let device1 = OutputDevice(id: 1, uid: "device1", name: "Device 1", sampleRate: 48000)
    let device2 = OutputDevice(id: 2, uid: "device2", name: "Device 2", sampleRate: 48000)

    r.test("prepare once on a muted device, then restore → device restored to muted") {
        // Reset state
        muteState = [1: 1]  // device1 is muted
        writeLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute)
        audibility.prepare(device1)
        audibility.restore(device1)

        // Verify: should have written unmute (0) then restore to mute (1)
        try expectEqual(writeLog.count, 2)
        try expectEqual(writeLog[0].0, AudioObjectID(1))
        try expectEqual(writeLog[0].1, UInt32(0))  // unmute
        try expectEqual(writeLog[1].0, AudioObjectID(1))
        try expectEqual(writeLog[1].1, UInt32(1))  // restore to muted
    }

    r.test("prepare TWICE then restore ONCE → device still restored to original muted state") {
        // This is the regression test: second prepare() must not clobber the stored state
        muteState = [1: 1]  // device1 is muted
        writeLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute)

        // First prepare: reads muted (1), stores it, writes unmute (0)
        audibility.prepare(device1)
        try expectEqual(writeLog.count, 1)
        try expectEqual(writeLog[0].1, UInt32(0))  // first prepare unmutes

        // Second prepare: reads unmuted (0), but must NOT overwrite stored state
        // Should still write unmute (0) again
        audibility.prepare(device1)
        try expectEqual(writeLog.count, 2)
        try expectEqual(writeLog[1].1, UInt32(0))  // second prepare also unmutes

        // Now restore: should restore to the ORIGINAL muted state (1), not the current (0)
        audibility.restore(device1)
        try expectEqual(writeLog.count, 3)
        try expectEqual(writeLog[2].1, UInt32(1))  // restored to original muted state
    }

    r.test("restore with no preceding prepare → no write attempted") {
        writeLog = []
        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute)

        // Call restore without prepare
        audibility.restore(device1)

        // Should have attempted no writes
        try expectEqual(writeLog.count, 0)
    }

    r.test("two different devices tracked independently") {
        muteState = [1: 1, 2: 0]  // device1 muted, device2 unmuted
        writeLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute)

        // Prepare device1 (muted)
        audibility.prepare(device1)
        try expectEqual(writeLog.count, 1)
        try expectEqual(writeLog[0].0, AudioObjectID(1))
        try expectEqual(writeLog[0].1, UInt32(0))

        // Prepare device2 (unmuted)
        audibility.prepare(device2)
        try expectEqual(writeLog.count, 2)
        try expectEqual(writeLog[1].0, AudioObjectID(2))
        try expectEqual(writeLog[1].1, UInt32(0))

        // Restore device1: should restore to muted (1)
        audibility.restore(device1)
        try expectEqual(writeLog.count, 3)
        try expectEqual(writeLog[2].0, AudioObjectID(1))
        try expectEqual(writeLog[2].1, UInt32(1))

        // Restore device2: should restore to unmuted (0)
        audibility.restore(device2)
        try expectEqual(writeLog.count, 4)
        try expectEqual(writeLog[3].0, AudioObjectID(2))
        try expectEqual(writeLog[3].1, UInt32(0))
    }

    r.test("volume floor still runs on every prepare call") {
        // This verifies the guard on mute storage did not accidentally swallow volume floor.
        // The mute operations should happen regardless of volume floor, so we verify
        // prepare() writes unmute on both first and second call.
        muteState = [1: 0]  // device1 unmuted
        writeLog = []

        let audibility = DestinationAudibility(readMute: mockReadMute, writeMute: mockWriteMute)
        audibility.prepare(device1)
        try expectEqual(writeLog.count, 1)
        audibility.prepare(device1)
        try expectEqual(writeLog.count, 2)

        // Both prepares should have written unmute (0), proving volume floor doesn't bypass prepare
        try expectEqual(writeLog[0].1, UInt32(0))
        try expectEqual(writeLog[1].1, UInt32(0))
    }

    return r.summarise()
}
