import Foundation
import CoreAudio
import SpotifyRouteCore

// --- fakes ---

final class FakeStore: SettingsStore {
    var settings = Settings()
    func load() -> Settings { settings }
    func save(_ s: Settings) throws { settings = s }
}

final class FakeRouter: Routing {
    var isActive = false
    var activeDestinationUID: String?
    var enableCalls: [String] = []
    var disableCount = 0
    var errorToThrow: Error?

    func enable(destination: OutputDevice, processObject: AudioObjectID) throws {
        if let e = errorToThrow { throw e }
        enableCalls.append(destination.uid)
        isActive = true
        activeDestinationUID = destination.uid
    }
    func disable() {
        disableCount += 1
        isActive = false
        activeDestinationUID = nil
    }
}

final class FakeDevices: DeviceListing {
    var devices: [OutputDevice] = [
        OutputDevice(id: 1, uid: "SPEAKERS", name: "Built-in Speakers", sampleRate: 48000),
        OutputDevice(id: 2, uid: "IFACE", name: "USB Interface", sampleRate: 48000),
    ]
    var defaultUID: String? = "IFACE"
    func allOutputDevices() throws -> [OutputDevice] { devices }
    func currentDefaultUID() -> String? { defaultUID }
}

final class FakeProcesses: ProcessLocating {
    var running = true
    func spotifyProcessObject() throws -> AudioObjectID {
        if !running { throw RouteError.spotifyNotRunning }
        return AudioObjectID(42)
    }
}

final class FakeAudibility: Audibility {
    var prepared: [String] = []
    var restored: [String] = []
    func prepare(_ d: OutputDevice) { prepared.append(d.uid) }
    func restore(_ d: OutputDevice) { restored.append(d.uid) }
}

private func makeController(
    store: FakeStore = FakeStore(),
    router: FakeRouter = FakeRouter(),
    devices: FakeDevices = FakeDevices(),
    processes: FakeProcesses = FakeProcesses(),
    audibility: FakeAudibility = FakeAudibility()
) -> (RouteController, FakeStore, FakeRouter, FakeDevices, FakeProcesses, FakeAudibility) {
    let c = RouteController(store: store, router: router, devices: devices,
                            processes: processes, audibility: audibility)
    return (c, store, router, devices, processes, audibility)
}

func runRouteControllerTests() -> Int {
    let r = TestRunner("RouteController")

    r.test("list names every output device and marks the default") {
        let (c, _, _, _, _, _) = makeController()
        guard case .ok(let body) = c.handle(.list) else {
            throw TestFailure("expected ok")
        }
        try expect(body.contains("SPEAKERS"), "lists the speakers UID")
        try expect(body.contains("USB Interface"), "lists the interface name")
        try expect(body.contains("default"), "marks the system default")
    }

    r.test("use rejects an unknown device UID") {
        let (c, _, _, _, _, _) = makeController()
        guard case .error(let msg) = c.handle(.use("NOPE")) else {
            throw TestFailure("expected error")
        }
        try expect(msg.contains("NOPE"), "names the offending UID")
    }

    r.test("use refuses the current system default") {
        let (c, _, _, _, _, _) = makeController()
        guard case .error(let msg) = c.handle(.use("IFACE")) else {
            throw TestFailure("expected error, routing a device to itself is pointless")
        }
        try expect(msg.lowercased().contains("default"), "explains why")
    }

    r.test("use stores the destination") {
        let (c, store, _, _, _, _) = makeController()
        guard case .ok = c.handle(.use("SPEAKERS")) else { throw TestFailure("expected ok") }
        try expectEqual(store.settings.destinationUID, "SPEAKERS")
    }

    r.test("on without a chosen destination is refused, not silently enabled") {
        let (c, store, router, _, _, _) = makeController()
        guard case .error(let msg) = c.handle(.on) else { throw TestFailure("expected error") }
        try expect(msg.contains("destination"), "explains what is missing")
        try expectEqual(router.enableCalls.count, 0)
        try expectEqual(store.settings.routeEnabled, false, "intent not persisted on failure")
    }

    r.test("on with a destination and Spotify running activates the route") {
        let (c, store, router, _, _, audibility) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        guard case .ok(let body) = c.handle(.on) else { throw TestFailure("expected ok") }
        try expectEqual(body, "on")
        try expectEqual(router.enableCalls, ["SPEAKERS"])
        try expectEqual(audibility.prepared, ["SPEAKERS"], "made the destination audible")
        try expectEqual(store.settings.routeEnabled, true)
    }

    r.test("on with Spotify not running arms rather than failing") {
        let processes = FakeProcesses()
        processes.running = false
        let (c, store, router, _, _, _) = makeController(processes: processes)
        _ = c.handle(.use("SPEAKERS"))
        guard case .ok(let body) = c.handle(.on) else { throw TestFailure("expected ok") }
        try expectEqual(body, "armed")
        try expectEqual(router.enableCalls.count, 0)
        try expectEqual(store.settings.routeEnabled, true, "intent persists so it applies later")
    }

    r.test("an armed route applies once Spotify appears") {
        let processes = FakeProcesses()
        processes.running = false
        let (c, _, router, _, _, _) = makeController(processes: processes)
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)
        processes.running = true
        c.reapply()
        try expectEqual(router.enableCalls, ["SPEAKERS"])
    }

    r.test("off tears down and restores the destination") {
        let (c, store, router, _, _, audibility) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)
        guard case .ok(let body) = c.handle(.off) else { throw TestFailure("expected ok") }
        try expectEqual(body, "off")
        try expect(router.disableCount >= 1, "router torn down")
        try expectEqual(audibility.restored, ["SPEAKERS"], "prior mute state restored")
        try expectEqual(store.settings.routeEnabled, false)
    }

    r.test("toggle alternates") {
        let (c, _, _, _, _, _) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        guard case .ok(let first) = c.handle(.toggle) else { throw TestFailure("expected ok") }
        try expectEqual(first, "on")
        guard case .ok(let second) = c.handle(.toggle) else { throw TestFailure("expected ok") }
        try expectEqual(second, "off")
    }

    r.test("changing destination while active rebuilds on the new device") {
        // Exercises handleUse's own re-apply branch on ONE running controller — not
        // two independently-configured ones — so it actually fails if that branch
        // (the "if settings.routeEnabled, router.isActive { return handleOn() }"
        // rebuild) were ever deleted. A prior draft of this test built a second
        // controller for the second `use`, which meant it never touched that branch
        // and would have kept passing with the rebuild logic removed entirely.
        let devices = FakeDevices()
        devices.defaultUID = nil          // neither device is the default, so both are usable
        let (c, _, router, _, _, audibility) = makeController(devices: devices)
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)
        try expectEqual(router.enableCalls, ["SPEAKERS"])

        guard case .ok = c.handle(.use("IFACE")) else { throw TestFailure("expected ok") }
        try expectEqual(router.enableCalls, ["SPEAKERS", "IFACE"],
                        "switching destination while active issues a fresh enable for the new device")
        try expectEqual(audibility.restored, ["SPEAKERS"],
                        "the old destination is restored to its prior mute state, not left " +
                        "unmuted forever, when a new destination takes over")
    }

    r.test("a router failure reports the error and does not claim success") {
        let router = FakeRouter()
        router.errorToThrow = RouteError.coreAudio("AudioDeviceStart", OSStatus(-10875))
        let (c, store, _, _, _, _) = makeController(router: router)
        _ = c.handle(.use("SPEAKERS"))
        guard case .error(let msg) = c.handle(.on) else { throw TestFailure("expected error") }
        try expect(msg.contains("AudioDeviceStart"), "surfaces the failing call")
        try expectEqual(store.settings.routeEnabled, false, "does not persist a broken state")
    }

    r.test("status reports the destination name, not just the UID") {
        // Exact match, not `.contains("on")`: the off-state string is
        // "off (destination: ...)", and "destinati-ON" contains "on" too, so a
        // `.contains("on")` assertion here would pass whether this actually reached
        // the active state or fell back to off — it could never fail either way.
        let (c, _, _, _, _, _) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)
        guard case .ok(let body) = c.handle(.status) else { throw TestFailure("expected ok") }
        try expectEqual(body, "on -> Built-in Speakers")
    }

    r.test("the chosen destination is readable without parsing display text") {
        let (c, _, _, _, _, _) = makeController()
        try expectNil(c.destinationUID)
        _ = c.handle(.use("SPEAKERS"))
        try expectEqual(c.destinationUID, "SPEAKERS")
    }

    r.test("a destination that has disappeared is reported clearly") {
        let devices = FakeDevices()
        let (c, _, _, _, _, _) = makeController(devices: devices)
        _ = c.handle(.use("SPEAKERS"))
        devices.devices.removeAll { $0.uid == "SPEAKERS" }
        guard case .error(let msg) = c.handle(.on) else { throw TestFailure("expected error") }
        try expect(msg.contains("SPEAKERS"), "names the missing device")
    }

    r.test("a repeated on while already active calls prepare again on the same device") {
        // Documents current behaviour: handleOn() has no re-entry guard, so calling
        // .on twice while already active invokes audibility.prepare(device) a second
        // time for the same device. This is safe today because DestinationAudibility
        // is first-observation-wins on the stored mute state (see its own tests), but
        // if that contract ever changes, this test should be the one that notices.
        let (c, _, router, _, _, audibility) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        guard case .ok = c.handle(.on) else { throw TestFailure("expected ok") }
        guard case .ok = c.handle(.on) else { throw TestFailure("expected ok") }
        try expectEqual(audibility.prepared, ["SPEAKERS", "SPEAKERS"],
                        "prepare is invoked once per .on call, even while already active")
        try expectEqual(router.enableCalls, ["SPEAKERS", "SPEAKERS"],
                        "enable is invoked once per .on call; FakeRouter records both, " +
                        "though the real AudioRouter treats a same-destination re-enable as a no-op")
    }

    r.test("on refuses once the persisted destination has become the system default") {
        // `use` already refuses picking a destination that IS the default, but the
        // default can drift after that: the destination was the built-in speakers
        // while a USB interface was default, the interface gets unplugged or sleeps,
        // and macOS promotes the speakers to default. `handleOn` must catch this too,
        // not just `handleUse` — otherwise the system default gets unmuted/enabled.
        let devices = FakeDevices()
        let (c, store, router, _, _, audibility) = makeController(devices: devices)
        _ = c.handle(.use("SPEAKERS"))   // fine: default is "IFACE" at this point
        devices.defaultUID = "SPEAKERS"  // the system default has since changed
        guard case .error(let msg) = c.handle(.on) else {
            throw TestFailure("expected error, the destination is now the system default")
        }
        try expect(msg.lowercased().contains("default"), "explains why")
        try expectEqual(router.enableCalls.count, 0, "must never enable a route onto the default")
        try expectEqual(audibility.prepared.count, 0, "must never touch the default's mute/volume")
        try expectEqual(store.settings.routeEnabled, false, "does not persist a refused activation")
    }

    r.test("reapply refuses re-applying once the destination has become the system default") {
        // The same drift, but reached through reapply() — the path actually taken at
        // login and on Spotify's launch, and the one the bug report calls out
        // explicitly since a human never runs it directly.
        let processes = FakeProcesses()
        processes.running = false
        let devices = FakeDevices()
        let (c, _, router, _, _, audibility) = makeController(devices: devices, processes: processes)
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)                // arms: Spotify absent, default still "IFACE"
        processes.running = true
        devices.defaultUID = "SPEAKERS"  // system default changed while armed
        c.reapply()
        try expectEqual(router.enableCalls.count, 0,
                        "reapply() must not enable a route onto the new system default")
        try expectEqual(audibility.prepared.count, 0,
                        "reapply() must not unmute/raise the volume of the system default")
    }

    return r.summarise()
}
