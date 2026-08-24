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

print("SpotifyRouteApp — menu bar arrives in Task 11")
