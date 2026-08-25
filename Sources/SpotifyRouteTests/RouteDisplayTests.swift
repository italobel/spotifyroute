import SpotifyRouteCore
import SpotifyRouteUI

private func devices() -> [OutputDevice] {
    [
        OutputDevice(id: 1, uid: "SPEAKERS", name: "Built-in Speakers", sampleRate: 48000),
        OutputDevice(id: 2, uid: "IFACE", name: "USB Interface", sampleRate: 48000),
    ]
}

func runRouteDisplayTests() -> Int {
    let r = TestRunner("RouteDisplay")

    r.test("route off names the chosen destination without claiming it is active") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: "SPEAKERS",
                                         devices: devices(), systemDefaultUID: "IFACE",
                                         spotify: .paused, activity: .idle)
        try expectEqual(d.routeLine, "Off — Built-in Speakers selected")
        try expectEqual(d.toggleTitle, "Turn On")
        try expect(d.toggleEnabled, "a destination is chosen, so the toggle works")
        try expectNil(d.problem)
    }

    r.test("an active route names where audio is actually going") {
        let d = RouteDisplayBuilder.build(status: .active(destinationUID: "SPEAKERS"),
                                         destinationUID: "SPEAKERS", devices: devices(),
                                         systemDefaultUID: "IFACE", spotify: .playing,
                                         activity: .idle)
        try expectEqual(d.routeLine, "On — playing through Built-in Speakers")
        try expectEqual(d.toggleTitle, "Turn Off")
    }

    r.test("armed explains it is waiting rather than looking broken") {
        let d = RouteDisplayBuilder.build(status: .armed(destinationUID: "SPEAKERS"),
                                         destinationUID: "SPEAKERS", devices: devices(),
                                         systemDefaultUID: "IFACE", spotify: .notRunning,
                                         activity: .idle)
        try expectEqual(d.routeLine, "Waiting for Spotify — will route to Built-in Speakers")
        try expectEqual(d.toggleTitle, "Turn Off")
    }

    r.test("no destination chosen disables the toggle and says so") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: nil,
                                         devices: devices(), systemDefaultUID: "IFACE",
                                         spotify: .paused, activity: .idle)
        try expectEqual(d.routeLine, "Off — no destination chosen")
        try expect(!d.toggleEnabled, "nothing to route to, so the toggle must be disabled")
    }

    r.test("misconfigured surfaces its reason as a problem") {
        let d = RouteDisplayBuilder.build(status: .misconfigured(reason: "no destination device chosen"),
                                         destinationUID: nil, devices: devices(),
                                         systemDefaultUID: "IFACE", spotify: .paused,
                                         activity: .idle)
        try expectEqual(d.problem, "no destination device chosen")
        try expectEqual(d.routeLine, "Not configured — no destination device chosen")
        try expect(!d.toggleEnabled, "cannot toggle a misconfigured route")
    }

    r.test("a destination that has disappeared is reported, not silently ignored") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: "GONE",
                                         devices: devices(), systemDefaultUID: "IFACE",
                                         spotify: .paused, activity: .idle)
        try expectEqual(d.routeLine, "Off — selected destination unavailable")
        try expect(d.problem?.contains("GONE") == true, "names the missing device")
        try expect(!d.toggleEnabled, "cannot route to a device that is not there")
    }

    r.test("the system default is listed but NOT selectable") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: "SPEAKERS",
                                         devices: devices(), systemDefaultUID: "IFACE",
                                         spotify: .paused, activity: .idle)
        guard let iface = d.devices.first(where: { $0.uid == "IFACE" }) else {
            throw TestFailure("the default device must still be listed")
        }
        try expect(iface.isSystemDefault, "marked as the default")
        try expect(!iface.isSelectable, "routing a device to itself is refused, so it must not be selectable")
        guard let speakers = d.devices.first(where: { $0.uid == "SPEAKERS" }) else {
            throw TestFailure("the chosen destination must be listed")
        }
        try expect(speakers.isSelectable, "a non-default device is selectable")
        try expect(speakers.isChosenDestination, "the chosen destination is flagged")
    }

    r.test("device rows preserve the order they were given") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: nil,
                                         devices: devices(), systemDefaultUID: nil,
                                         spotify: .paused, activity: .idle)
        try expectEqual(d.devices.map(\.uid), ["SPEAKERS", "IFACE"])
    }

    r.test("an empty device list is reported rather than shown as a blank list") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: nil, devices: [],
                                         systemDefaultUID: nil, spotify: .paused, activity: .idle)
        try expect(d.problem != nil, "an empty list must explain itself")
        try expect(!d.toggleEnabled, "nothing to route to")
    }

    r.test("spotify presence is reported for each of the three states") {
        for (presence, expected) in [(SpotifyPresence.playing, "Spotify is playing"),
                                     (SpotifyPresence.paused, "Spotify is paused"),
                                     (SpotifyPresence.notRunning, "Spotify is not running")] {
            let d = RouteDisplayBuilder.build(status: .off, destinationUID: "SPEAKERS",
                                             devices: devices(), systemDefaultUID: "IFACE",
                                             spotify: presence, activity: .idle)
            try expectEqual(d.spotifyLine, expected, "presence \(presence)")
        }
    }

    r.test("working activity replaces the route line and disables the toggle") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: "SPEAKERS",
                                         devices: devices(), systemDefaultUID: "IFACE",
                                         spotify: .paused, activity: .working)
        try expectEqual(d.routeLine, "Working…")
        try expect(!d.toggleEnabled, "no double-clicking while a command is in flight")
    }

    r.test("an active route with a missing destination is still closeable") {
        let d = RouteDisplayBuilder.build(status: .active(destinationUID: "GONE"),
                                         destinationUID: "GONE", devices: devices(),
                                         systemDefaultUID: "IFACE", spotify: .playing,
                                         activity: .idle)
        try expectEqual(d.toggleTitle, "Turn Off")
        try expect(d.toggleEnabled, "route is on, so turning it off must be possible even if destination vanished")
    }

    r.test("an armed route with a missing destination is still closeable") {
        let d = RouteDisplayBuilder.build(status: .armed(destinationUID: "GONE"),
                                         destinationUID: "GONE", devices: devices(),
                                         systemDefaultUID: "IFACE", spotify: .paused,
                                         activity: .idle)
        try expectEqual(d.toggleTitle, "Turn Off")
        try expect(d.toggleEnabled, "route is on, so turning it off must be possible even if destination vanished")
    }

    r.test("cannot turn on a route if the destination is not available") {
        let d = RouteDisplayBuilder.build(status: .off, destinationUID: "GONE",
                                         devices: devices(), systemDefaultUID: "IFACE",
                                         spotify: .paused, activity: .idle)
        try expectEqual(d.toggleTitle, "Turn On")
        try expect(!d.toggleEnabled, "the destination does not exist, so turning on is impossible")
    }

    return r.summarise()
}
