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

print("SpotifyRouteApp — menu bar arrives in Task 11")
