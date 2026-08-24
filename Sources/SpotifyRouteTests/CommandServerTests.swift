import Foundation
@testable import SpotifyRouteCore

func runCommandServerTests() -> Int {
    let r = TestRunner("CommandServer")

    r.test("selftest handler timeout is derived, and exceeds the worst-case selftest run") {
        // CommandServer.selfTestHandlerTimeout must be built from the same named
        // constants SelfTest.run actually sleeps against (readinessCeiling,
        // defaultMeasurementSeconds) plus a positive cushion — not a hand-picked
        // number that raising SelfTest.readinessPollIterations could silently fall
        // behind. This only constructs a CommandServer (no start()), so it touches no
        // socket and has no side effects.
        let socketURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spotifyroute-tests-\(getpid())-cmdserver.sock")
        let server = CommandServer(socketURL: socketURL) { _ in .ok("") }

        let derivedWorstCase = SelfTest.readinessCeiling + SelfTest.defaultMeasurementSeconds
        try expect(server.selfTestHandlerTimeout > derivedWorstCase,
                   "handler timeout (\(server.selfTestHandlerTimeout)s) must exceed the " +
                   "derived worst-case selftest duration (\(derivedWorstCase)s) — otherwise " +
                   "a genuinely successful, just-slow selftest is reported as \"app busy\"")
    }

    return r.summarise()
}
