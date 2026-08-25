import SpotifyRouteCore
import SpotifyRouteUI

func runAppStateTests() -> Int {
    let r = TestRunner("AppState")

    let devs = [
        OutputDevice(id: 1, uid: "SPEAKERS", name: "Built-in Speakers", sampleRate: 48000),
        OutputDevice(id: 2, uid: "IFACE", name: "USB Interface", sampleRate: 48000),
    ]

    func snapshot(_ status: RouteStatus,
                  _ destination: String?,
                  _ spotify: SpotifyPresence = .paused) -> AppState.Snapshot {
        AppState.Snapshot(status: status, destinationUID: destination, devices: devs,
                          systemDefaultUID: "IFACE", spotify: spotify)
    }

    r.test("applying a snapshot publishes a display derived from it") {
        let s = AppState()
        s.apply(snapshot(.active(destinationUID: "SPEAKERS"), "SPEAKERS", .playing))
        try expectEqual(s.display.routeLine, "On — playing through Built-in Speakers")
        try expectEqual(s.display.spotifyLine, "Spotify is playing")
    }

    r.test("a later snapshot replaces the earlier one") {
        let s = AppState()
        s.apply(snapshot(.active(destinationUID: "SPEAKERS"), "SPEAKERS", .playing))
        s.apply(snapshot(.off, "SPEAKERS", .paused))
        try expectEqual(s.display.routeLine, "Off — Built-in Speakers selected")
        try expectEqual(s.display.toggleTitle, "Turn On")
    }

    r.test("beginWork shows working and disables the toggle") {
        let s = AppState()
        s.apply(snapshot(.off, "SPEAKERS"))
        s.beginWork()
        try expectEqual(s.display.routeLine, "Working…")
        try expect(!s.display.toggleEnabled, "no double-submits while working")
    }

    r.test("endWork restores the real state, not a stale working line") {
        let s = AppState()
        s.apply(snapshot(.off, "SPEAKERS"))
        s.beginWork()
        s.endWork()
        try expectEqual(s.display.routeLine, "Off — Built-in Speakers selected")
        try expect(s.display.toggleEnabled, "usable again once work finishes")
    }

    r.test("a snapshot applied while working still ends up visible after endWork") {
        let s = AppState()
        s.apply(snapshot(.off, "SPEAKERS"))
        s.beginWork()
        s.apply(snapshot(.active(destinationUID: "SPEAKERS"), "SPEAKERS", .playing))
        try expectEqual(s.display.routeLine, "Working…", "working wins while in flight")
        s.endWork()
        try expectEqual(s.display.routeLine, "On — playing through Built-in Speakers",
                        "the snapshot that arrived during the work is not lost")
    }

    r.test("endWork called without new beginWork does not corrupt state") {
        let s = AppState()
        s.apply(snapshot(.off, "SPEAKERS"))
        s.beginWork()
        s.endWork()
        try expectEqual(s.display.routeLine, "Off — Built-in Speakers selected",
                        "display restored after work completes")
        s.endWork()
        try expectEqual(s.display.routeLine, "Off — Built-in Speakers selected",
                        "second endWork call without new beginWork leaves real state intact")
    }

    return r.summarise()
}
