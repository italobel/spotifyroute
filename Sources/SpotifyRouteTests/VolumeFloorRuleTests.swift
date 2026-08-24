import SpotifyRouteCore

func runVolumeFloorRuleTests() -> Int {
    let r = TestRunner("VolumeFloorRule")

    r.test("a muted-silent device is raised to the target") {
        try expectEqual(VolumeFloorRule.desiredVolume(current: 0.0), 0.5)
    }
    r.test("a volume below the floor is raised to the target") {
        try expectEqual(VolumeFloorRule.desiredVolume(current: 0.1), 0.5)
    }
    r.test("a volume exactly at the floor is left alone") {
        try expectNil(VolumeFloorRule.desiredVolume(current: 0.2))
    }
    r.test("an already-audible volume is never lowered") {
        try expectNil(VolumeFloorRule.desiredVolume(current: 0.55))
        try expectNil(VolumeFloorRule.desiredVolume(current: 1.0))
    }
    r.test("an unreadable volume falls back to the target") {
        try expectEqual(VolumeFloorRule.desiredVolume(current: nil), 0.5)
    }

    return r.summarise()
}
