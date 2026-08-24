import SpotifyRouteCore

func runProtocolTests() -> Int {
    let r = TestRunner("Protocol")

    r.test("bare verbs parse") {
        try expectEqual(parseCommand("on"), .success(.on))
        try expectEqual(parseCommand("off"), .success(.off))
        try expectEqual(parseCommand("toggle"), .success(.toggle))
        try expectEqual(parseCommand("status"), .success(.status))
        try expectEqual(parseCommand("list"), .success(.list))
        try expectEqual(parseCommand("selftest"), .success(.selftest))
    }
    r.test("verbs are case-insensitive and whitespace-tolerant") {
        try expectEqual(parseCommand("  ON  "), .success(.on))
        try expectEqual(parseCommand("Toggle"), .success(.toggle))
    }
    r.test("use carries its argument verbatim, preserving case") {
        try expectEqual(parseCommand("use BuiltInSpeakerDevice"),
                        .success(.use("BuiltInSpeakerDevice")))
    }
    r.test("device UIDs containing spaces survive parsing") {
        try expectEqual(parseCommand("use AppleUSBAudioEngine:RODE:RODECaster Pro II:1"),
                        .success(.use("AppleUSBAudioEngine:RODE:RODECaster Pro II:1")))
    }
    r.test("use without an argument is rejected") {
        try expectEqual(parseCommand("use"), .failure(.missingArgument("use")))
        try expectEqual(parseCommand("use   "), .failure(.missingArgument("use")))
    }
    r.test("empty input is rejected") {
        try expectEqual(parseCommand(""), .failure(.empty))
        try expectEqual(parseCommand("   "), .failure(.empty))
    }
    r.test("unknown verbs are reported with the offending word") {
        try expectEqual(parseCommand("frobnicate"), .failure(.unknown("frobnicate")))
    }
    r.test("commands round-trip through encoding") {
        for c: Command in [.on, .off, .toggle, .status, .list, .selftest, .use("XYZ")] {
            try expectEqual(parseCommand(encodeCommand(c)), .success(c), "round-trip \(c)")
        }
    }
    r.test("replies encode and parse") {
        try expectEqual(encodeReply(.ok("on")), "ok on")
        try expectEqual(encodeReply(.error("no such device")), "error no such device")
        try expectEqual(parseReply("ok armed"), .ok("armed"))
        try expectEqual(parseReply("error nope"), .error("nope"))
    }
    r.test("an unrecognised reply is treated as an error rather than silently ignored") {
        try expectEqual(parseReply("garbage"), .error("garbage"))
    }

    return r.summarise()
}
