import Foundation
import SpotifyRouteCore

func runSettingsTests() -> Int {
    let r = TestRunner("Settings")

    r.test("a disabled route is off regardless of destination or activity") {
        let s = Settings(routeEnabled: false, destinationUID: "ABC")
        try expectEqual(RouteStatusRule.derive(settings: s, isActive: false), .off)
        try expectEqual(RouteStatusRule.derive(settings: s, isActive: true), .off)
    }
    r.test("enabled with a destination and running is active") {
        let s = Settings(routeEnabled: true, destinationUID: "ABC")
        try expectEqual(RouteStatusRule.derive(settings: s, isActive: true),
                        .active(destinationUID: "ABC"))
    }
    r.test("enabled with a destination but not running is armed") {
        let s = Settings(routeEnabled: true, destinationUID: "ABC")
        try expectEqual(RouteStatusRule.derive(settings: s, isActive: false),
                        .armed(destinationUID: "ABC"))
    }
    r.test("enabled with no destination is misconfigured, not silently off") {
        let s = Settings(routeEnabled: true, destinationUID: nil)
        try expectEqual(RouteStatusRule.derive(settings: s, isActive: false),
                        .misconfigured(reason: "no destination device chosen"))
    }
    r.test("status labels are stable — the Stream Deck and menu bar depend on them") {
        try expectEqual(RouteStatus.off.shortLabel, "off")
        try expectEqual(RouteStatus.active(destinationUID: "A").shortLabel, "on")
        try expectEqual(RouteStatus.armed(destinationUID: "A").shortLabel, "armed")
        try expectEqual(RouteStatus.misconfigured(reason: "x").shortLabel, "misconfigured")
    }

    // --- persistence ---
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("spotifyroute-tests-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    r.test("settings round-trip through a file") {
        let url = tmp.appendingPathComponent("roundtrip.json")
        let store = FileSettingsStore(url: url)
        try store.save(Settings(routeEnabled: true, destinationUID: "BuiltInSpeakerDevice"))
        let loaded = store.load()
        try expectEqual(loaded.routeEnabled, true)
        try expectEqual(loaded.destinationUID, "BuiltInSpeakerDevice")
    }
    r.test("a missing file loads defaults rather than throwing") {
        let store = FileSettingsStore(url: tmp.appendingPathComponent("does-not-exist.json"))
        let loaded = store.load()
        try expectEqual(loaded.routeEnabled, false)
        try expectNil(loaded.destinationUID)
    }
    r.test("a corrupt file loads defaults rather than crashing at login") {
        let url = tmp.appendingPathComponent("corrupt.json")
        try "{ this is not json".write(to: url, atomically: true, encoding: .utf8)
        let loaded = FileSettingsStore(url: url).load()
        try expectEqual(loaded.routeEnabled, false)
    }
    r.test("saving creates intermediate directories") {
        let url = tmp.appendingPathComponent("nested/deeper/settings.json")
        try FileSettingsStore(url: url).save(Settings(routeEnabled: true, destinationUID: "Z"))
        try expect(FileManager.default.fileExists(atPath: url.path), "file was created")
    }

    return r.summarise()
}
