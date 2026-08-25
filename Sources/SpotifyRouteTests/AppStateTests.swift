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

    r.test("a failed command's reply text becomes visible") {
        let s = AppState()
        try expectNil(s.commandFailure, "nothing has failed yet")
        s.recordReply(.error("permission denied"))
        try expectEqual(s.commandFailure, "permission denied")
    }

    r.test("a subsequent successful command clears a prior failure") {
        let s = AppState()
        s.recordReply(.error("permission denied"))
        try expectEqual(s.commandFailure, "permission denied")
        s.recordReply(.ok("on -> Built-in Speakers"))
        try expectNil(s.commandFailure, "success clears the old failure")
    }

    r.test("an unrelated snapshot does not clear a failure — only another command's own outcome does") {
        let s = AppState()
        s.recordReply(.error("permission denied"))
        s.apply(snapshot(.off, "SPEAKERS"))
        try expectEqual(s.commandFailure, "permission denied",
                        "a snapshot pushed by e.g. a device-change refresh carries no news about the last command")
    }

    r.test("a snapshot whose status changed clears a stale failure even without recordReply") {
        // Models the CLI/Stream Deck/reapply() paths: none of them call recordReply,
        // but a status transition is itself proof the failed window command is stale.
        let s = AppState()
        s.apply(snapshot(.off, "SPEAKERS"))
        s.recordReply(.error("permission denied"))
        s.apply(snapshot(.active(destinationUID: "SPEAKERS"), "SPEAKERS", .playing))
        try expectNil(s.commandFailure,
                      "the route actually turned on since the failure, so it can no longer be true")
    }

    r.test("a same-status snapshot right after recording a failure does not clear it") {
        // Guards against self-clearing: a failed command's own follow-up refresh
        // reports the same status that was already on file (RouteController never
        // persists a failed intent), so this must not be mistaken for a transition.
        let s = AppState()
        s.apply(snapshot(.active(destinationUID: "SPEAKERS"), "SPEAKERS", .playing))
        s.recordReply(.error("could not switch destination"))
        s.apply(snapshot(.active(destinationUID: "SPEAKERS"), "SPEAKERS", .playing))
        try expectEqual(s.commandFailure, "could not switch destination",
                        "status did not actually change, so the failure is still live")
    }

    return r.summarise()
}
