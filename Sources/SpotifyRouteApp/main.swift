import Foundation
import SpotifyRouteCore

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--list-devices" {
    do {
        let devices = try OutputDevices.all()
        let defaultUID = OutputDevices.currentDefaultUID()
        for device in devices {
            let marker = device.uid == defaultUID ? " (system default)" : ""
            print("\(device.name)\(marker)")
            print("    uid=\(device.uid)  \(Int(device.sampleRate)) Hz")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if args.first == "--selftest" {
    // Second argument is an optional destination UID; defaults to built-in speakers.
    // A UID that WAS supplied but does not resolve must fail rather than silently
    // fall back (I-5 review): built-in speakers is the one destination class where
    // the C-1 tap-offset bug was invisible, so a typo would silently test the safe
    // case and report PASS instead of surfacing the mistake.
    do {
        let devices = try OutputDevices.all()
        let requested = args.count > 1 ? args[1] : nil
        let destination: OutputDevice
        if let uid = requested {
            guard let match = devices.first(where: { $0.uid == uid }) else {
                throw RouteError.deviceNotFound(uid)
            }
            destination = match
        } else {
            guard let fallback = devices.first(where: { $0.uid == "BuiltInSpeakerDevice" })
                    ?? devices.first
            else {
                print("no output devices available")
                exit(1)
            }
            destination = fallback
        }
        print("self-testing against \(destination.name) (\(destination.uid))")
        let outcome = try SelfTest.run(destination: destination, seconds: 3)
        print("callbacks=\(outcome.callbacks) peak=\(outcome.peak)")
        print(outcome.passed ? "PASS — \(outcome.detail)" : "FAIL — \(outcome.detail)")
        exit(outcome.passed ? 0 : 1)
    } catch {
        print("FAIL — \(error)")
        exit(1)
    }
}

if args.first == "--show-audibility" {
    do {
        for device in try OutputDevices.all() {
            let volume = DestinationAudibility.readVolume(device.id)
            let mute = DestinationAudibility.readMute(device.id)
            let volumeText = volume.map { String(format: "%.3f", $0) } ?? "n/a"
            let muteText = mute.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
            print("\(device.name): volume=\(volumeText) \(muteText)")
        }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

if args.first == "--audibility-selftest" {
    // Temporary diagnostic: verify that repeated prepare() calls do not clobber
    // the stored prior mute state. Uses MacBook Pro Speakers (BuiltInSpeakerDevice),
    // which is the only device on this machine with working software mute.
    do {
        let devices = try OutputDevices.all()
        guard let device = devices.first(where: { $0.uid == "BuiltInSpeakerDevice" }) else {
            print("MacBook Pro Speakers (BuiltInSpeakerDevice) not found")
            exit(1)
        }

        print("Testing first-observation-wins mute preservation on \(device.name)...")

        // Step 1: Record current mute state
        let originalMute = DestinationAudibility.readMute(device.id)
        let originalMuteText = originalMute.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
        print("Step 1: Current mute state: \(originalMuteText)")

        // Step 2: Set it muted
        _ = DestinationAudibility.writeMute(device.id, 1)
        let afterMute = DestinationAudibility.readMute(device.id)
        let afterMuteText = afterMute.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
        print("Step 2: After writing mute=1: \(afterMuteText)")

        // Step 3: Call prepare() twice
        let audibility = DestinationAudibility()
        print("Step 3a: Calling prepare() first time...")
        audibility.prepare(device)
        let after1stPrepare = DestinationAudibility.readMute(device.id)
        let after1stPrepareText = after1stPrepare.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
        print("         After first prepare(): \(after1stPrepareText)")

        print("Step 3b: Calling prepare() second time...")
        audibility.prepare(device)
        let after2ndPrepare = DestinationAudibility.readMute(device.id)
        let after2ndPrepareText = after2ndPrepare.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
        print("         After second prepare(): \(after2ndPrepareText)")

        // Step 4: Call restore() once
        print("Step 4: Calling restore()...")
        audibility.restore(device)
        let afterRestore = DestinationAudibility.readMute(device.id)
        let afterRestoreText = afterRestore.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
        print("        After restore(): \(afterRestoreText)")

        // Step 5: Verify it matches the original (before we set it muted)
        let expectedAfterRestore: UInt32 = 1  // We set it to muted in step 2
        let testPassed = afterRestore == expectedAfterRestore
        print("Step 5: Verification: expected muted (1), got \(afterRestoreText)")
        print("        Test result: \(testPassed ? "PASS" : "FAIL")")

        // Step 6: Restore device to original state
        print("Step 6: Restoring device to original state (\(originalMuteText))...")
        if let original = originalMute {
            _ = DestinationAudibility.writeMute(device.id, original)
        }
        let finalMute = DestinationAudibility.readMute(device.id)
        let finalMuteText = finalMute.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
        print("        Final mute state: \(finalMuteText)")

        exit(testPassed ? 0 : 1)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

print("SpotifyRouteApp — menu bar arrives in Task 11")
