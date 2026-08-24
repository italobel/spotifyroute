# SpotifyRoute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu-bar app plus CLI that routes Spotify's audio to a user-chosen output device using Core Audio process taps, while leaving the system default output completely untouched, toggleable from a Stream Deck button.

**Architecture:** A single library target holds all logic and Core Audio code. Three executables consume it: `SpotifyRouteApp` (the bundled menu-bar app that owns every Core Audio object), `spotroute` (a thin Unix-socket client), and `SpotifyRouteTests` (a plain executable test runner). All tap work happens inside the app bundle because an unbundled binary silently receives zeroed audio — see Global Constraints.

**Tech Stack:** Swift 6.2, SwiftPM, CoreAudio / AudioToolbox, AppKit. No external dependencies. Command Line Tools only — no Xcode.

**Spec:** `docs/superpowers/specs/2026-08-24-spotify-route-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Minimum macOS: 14.2.** Verified only on 26.6 — the README must say exactly that, never implying tested support below it.
- **macOS 26-only APIs** (`bundleIDs`, `isProcessRestoreEnabled`) must sit behind `if #available(macOS 26.0, *)` and never be required for correctness.
- **All Core Audio tap code runs inside `SpotifyRouteApp`; `spotroute` is only a socket client.** This structure holds regardless of the permission question below — one owner for every audio object, and a thin client. It was originally motivated by an observation that an unbundled binary creates the tap, reports a valid format, delivers correctly sized buffers, and returns all-zero samples with no error and no prompt. **That observation is now UNVERIFIED**: it became unreproducible in the development environment, where every process descends from an app already holding audio-capture permission and TCC's responsible-process attribution appears to extend it across the process tree, masking the boundary for any code. Task 15 Step 0 settles it from a clean process tree. The architecture does not depend on the answer; the README does.
- **Ad-hoc signing only:** `codesign --force --sign - --identifier com.italo.spotifyroute`. No Developer ID, no Apple Developer Program.
- **Never modify the system default output device, and never let routing depend on its identity.** The tap is not bound to a source device; there is no "source device" concept anywhere in the code. Exactly one permitted read exists, in `OutputDevices.currentDefaultUID()`, solely to refuse routing a device to itself.
- **Destination identity is the device UID**, never its name. Names collide and change.
- **Volume floor rule (exact):** unmute unconditionally; raise volume to `0.5` only if currently below `0.2`; never lower an already-audible volume. On disable restore the prior *mute* state only, never the prior volume.
- **Spotify bundle identifier:** `com.spotify.client`.
- **Socket path:** `~/Library/Application Support/SpotifyRoute/control.sock`.
- **Verified tap recipe** (do not deviate without re-measuring): `muteBehavior = .mutedWhenTapped`, `isPrivate = true`; aggregate with destination UID as `kAudioAggregateDeviceMainSubDeviceKey`, `IsPrivate` true, `IsStacked` false, `TapAutoStart` true, destination in `SubDeviceList`, tap in `TapList` with `kAudioSubTapDriftCompensationKey: true`.
- **No external dependencies.** No test framework — XCTest and swift-testing both require Xcode and are unavailable here.
- **License:** MIT.

## File Structure

```
Package.swift                              SwiftPM manifest: 1 library, 3 executables
build.sh                                   compile, assemble .app, ad-hoc sign, install CLI
LICENSE                                    MIT
README.md                                  what it does, macOS floor, permission caveat
Sources/
  SpotifyRouteCore/                        all logic and Core Audio (library)
    TestHarness.swift                      assertion harness (public; used by test exe)
    CoreAudioSupport.swift                 property get/set wrappers, FourCC, RouteError
    Protocol.swift                         command parsing + reply formatting (pure)
    Settings.swift                          persisted intent + status derivation (pure)
    VolumeFloorRule.swift                  the volume decision as a pure function
    OutputDevices.swift                    enumerate output devices, resolve UID
    DestinationAudibility.swift            applies mute/volume to a real device
    AudioRouter.swift                      tap + aggregate + IOProc lifecycle
    SpotifyProcess.swift                   locate Spotify's Core Audio process object
    SpotifyWatcher.swift                   launch/quit + isRunningOutput observation
    CommandServer.swift                    Unix domain socket listener
    SelfTest.swift                          on-hardware RMS verification
  SpotifyRouteApp/
    main.swift                             NSApplication setup, argv --selftest path
    MenuBarController.swift                status item, toggle, destination picker
  spotroute/
    main.swift                             socket client, argv -> command
  SpotifyRouteTests/
    main.swift                             registers and runs every test suite
    ProtocolTests.swift
    SettingsTests.swift
    VolumeFloorRuleTests.swift
```

Rationale: `SpotifyRouteCore` is one library rather than several so the three executables share it without cross-target plumbing, but each *file* owns exactly one responsibility. Pure logic (`Protocol`, `Settings`, `VolumeFloorRule`) is deliberately separated from hardware-touching code (`OutputDevices`, `AudioRouter`, `DestinationAudibility`) precisely because only the former can be unit-tested; the latter is covered by `SelfTest` on real hardware.

---

### Task 1: Package skeleton and test harness

Nothing can be tested until there is a way to run tests. This task ends with a red test turning green.

**Files:**
- Create: `Package.swift`
- Create: `Sources/SpotifyRouteCore/TestHarness.swift`
- Create: `Sources/SpotifyRouteCore/VolumeFloorRule.swift`
- Create: `Sources/SpotifyRouteTests/main.swift`
- Create: `Sources/SpotifyRouteTests/VolumeFloorRuleTests.swift`
- Create: `Sources/SpotifyRouteApp/main.swift` (stub)
- Create: `Sources/spotroute/main.swift` (stub)
- Create: `.gitignore` (already exists — verify `.build/` is listed)

**Interfaces:**
- Consumes: nothing.
- Produces: `TestRunner(_ name: String)`, `TestRunner.test(_ label: String, _ body: () throws -> Void)`, `TestRunner.summarise() -> Int` (returns the failure count so `main.swift` can aggregate several suites), `expect(_ cond: Bool, _ msg: String) throws`, `expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ msg: String) throws`, `VolumeFloorRule.desiredVolume(current: Float?) -> Float?`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode is deliberate. Real-time Core Audio IOProc callbacks use
// patterns that predate strict concurrency; Swift 6 mode would demand a scattering of
// @unchecked Sendable annotations for no real safety gain in a design where shared
// state is already guarded by an explicit lock.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SpotifyRoute",
    // 14.2 exactly, not 14.0: that is where AudioHardwareCreateProcessTap landed.
    // Declaring 14.0 would force an #available guard around every tap call.
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "SpotifyRouteCore", swiftSettings: swift5),
        .executableTarget(name: "SpotifyRouteApp",
                          dependencies: ["SpotifyRouteCore"], swiftSettings: swift5),
        .executableTarget(name: "spotroute",
                          dependencies: ["SpotifyRouteCore"], swiftSettings: swift5),
        .executableTarget(name: "SpotifyRouteTests",
                          dependencies: ["SpotifyRouteCore"], swiftSettings: swift5),
    ]
)
```

- [ ] **Step 2: Write the test harness**

`Sources/SpotifyRouteCore/TestHarness.swift`:

```swift
import Foundation

/// Minimal assertion harness. XCTest and swift-testing both ship with Xcode and are
/// unavailable in a Command Line Tools-only toolchain, which this project targets.
public struct TestFailure: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public final class TestRunner {
    private var passed = 0
    private var failures: [(String, String)] = []
    private let suiteName: String

    public init(_ suiteName: String) { self.suiteName = suiteName }

    public func test(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("  ok    \(label)")
        } catch let failure as TestFailure {
            failures.append((label, failure.message))
            print("  FAIL  \(label) — \(failure.message)")
        } catch {
            failures.append((label, "\(error)"))
            print("  FAIL  \(label) — threw \(error)")
        }
    }

    /// Returns the number of failures so a caller can aggregate several suites.
    public func summarise() -> Int {
        print("\(suiteName): \(passed) passed, \(failures.count) failed\n")
        return failures.count
    }
}

public func expect(_ condition: Bool,
                   _ message: String = "expectation failed",
                   line: UInt = #line) throws {
    if !condition { throw TestFailure("\(message) (line \(line))") }
}

public func expectEqual<T: Equatable>(_ actual: T,
                                      _ expected: T,
                                      _ message: String = "",
                                      line: UInt = #line) throws {
    if actual != expected {
        let prefix = message.isEmpty ? "" : message + ": "
        throw TestFailure("\(prefix)expected \(expected), got \(actual) (line \(line))")
    }
}

public func expectNil<T>(_ value: T?, _ message: String = "", line: UInt = #line) throws {
    if let value { throw TestFailure("\(message) expected nil, got \(value) (line \(line))") }
}
```

- [ ] **Step 3: Write the failing test**

`Sources/SpotifyRouteTests/VolumeFloorRuleTests.swift`:

```swift
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
```

`Sources/SpotifyRouteTests/main.swift`:

```swift
import Foundation

var failures = 0
failures += runVolumeFloorRuleTests()

if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift run SpotifyRouteTests`
Expected: compile failure — `cannot find 'VolumeFloorRule' in scope`. This is the correct first red: the type does not exist yet.

- [ ] **Step 5: Write the minimal implementation**

`Sources/SpotifyRouteCore/VolumeFloorRule.swift`:

```swift
/// Decides whether a destination device's volume needs raising to be audible.
///
/// Exists because an output device that is not the system default keeps its own
/// volume and mute state, untouched by the keyboard volume keys. During development
/// the first audible test failed purely because the destination was muted at the
/// device level while reporting volume 1.000.
public enum VolumeFloorRule {
    /// Below this, the device is considered inaudible.
    public static let floor: Float = 0.2
    /// What we raise an inaudible device to.
    public static let target: Float = 0.5

    /// - Parameter current: the device's current scalar volume, or nil if unreadable.
    /// - Returns: the volume to set, or nil to leave the volume untouched.
    public static func desiredVolume(current: Float?) -> Float? {
        guard let current else { return target }
        return current < floor ? target : nil
    }
}
```

- [ ] **Step 6: Write the executable stubs so the package builds**

`Sources/SpotifyRouteApp/main.swift`:

```swift
import Foundation
print("SpotifyRouteApp stub — replaced in Task 11")
```

`Sources/spotroute/main.swift`:

```swift
import Foundation
print("spotroute stub — replaced in Task 9")
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift run SpotifyRouteTests`
Expected: five `ok` lines, `VolumeFloorRule: 5 passed, 0 failed`, then `ALL TESTS PASSED`, exit 0.

- [ ] **Step 8: Verify the whole package builds**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 9: Commit**

```bash
git add Package.swift .gitignore Sources
git commit -m "Add package skeleton and a CLT-only test harness

XCTest and swift-testing both ship with Xcode and are unavailable in a
Command Line Tools-only toolchain, which this project deliberately targets
so contributors need no 10GB install. A ~50 line assertion harness gives
real red/green TDD with no dependencies."
```

---

### Task 2: build.sh — app bundle, Info.plist, ad-hoc signing

This comes second, before any audio code, because a process tap in an unbundled binary silently returns zeroed samples. Without the bundle there is no way to verify any later task.

**Files:**
- Create: `build.sh`
- Create: `Resources/Info.plist.template`

**Interfaces:**
- Consumes: the `SpotifyRouteApp` and `spotroute` executables from Task 1.
- Produces: `./build/SpotifyRoute.app` (ad-hoc signed, containing `NSAudioCaptureUsageDescription`) and `./build/spotroute`.

- [ ] **Step 1: Write the Info.plist template**

`Resources/Info.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.italo.spotifyroute</string>
  <key>CFBundleExecutable</key><string>SpotifyRouteApp</string>
  <key>CFBundleName</key><string>SpotifyRoute</string>
  <key>CFBundleDisplayName</key><string>SpotifyRoute</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>SpotifyRoute captures Spotify's audio so it can play through the output device you choose, leaving your system default output unchanged.</string>
</dict>
</plist>
```

- [ ] **Step 2: Write build.sh**

```bash
#!/bin/bash
# Builds SpotifyRoute with Command Line Tools only. No Xcode required.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/SpotifyRoute.app"
BUNDLE_ID="com.italo.spotifyroute"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist.template" "$APP/Contents/Info.plist"
cp "$BIN/SpotifyRouteApp" "$APP/Contents/MacOS/SpotifyRouteApp"

echo "==> Ad-hoc signing"
# Ad-hoc signing is sufficient for Core Audio process taps; no Developer ID needed.
# The TCC grant binds to the binary's cdhash, so rebuilding may require re-granting
# audio permission. A silent route almost always means exactly that.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

echo "==> Installing CLI"
mkdir -p "$OUT"
cp "$BIN/spotroute" "$OUT/spotroute"

cat <<EOF

Build complete.

  App: $APP
  CLI: $OUT/spotroute

Next:
  1. open "$APP"                       # launches the menu-bar app
  2. "$OUT/spotroute" list             # show available output devices
  3. "$OUT/spotroute" use <device-uid> # pick where Spotify should play
  4. "$OUT/spotroute" on               # route it

To install the CLI on your PATH:
  sudo cp "$OUT/spotroute" /usr/local/bin/spotroute
EOF
```

- [ ] **Step 3: Make it executable and run it**

```bash
chmod +x build.sh
./build.sh
```

Expected: build succeeds; output shows `Identifier=com.italo.spotifyroute` and `Signature=adhoc`.

- [ ] **Step 4: Verify the bundle carries the permission key**

Run: `/usr/libexec/PlistBuddy -c "Print :NSAudioCaptureUsageDescription" build/SpotifyRoute.app/Contents/Info.plist`
Expected: the usage string prints. If this key is ever missing, every tap returns silence.

- [ ] **Step 5: Verify the bundled stub actually launches**

Run: `build/SpotifyRoute.app/Contents/MacOS/SpotifyRouteApp`
Expected: prints the Task 1 stub line and exits 0.

- [ ] **Step 6: Commit**

```bash
git add build.sh Resources
git commit -m "Add build script producing an ad-hoc signed .app bundle

The bundle plus NSAudioCaptureUsageDescription is not cosmetic: an
unbundled binary creates a process tap successfully, reports a valid
stream format, delivers correctly sized buffers, and every sample is
zero, with no error and no permission prompt. Nothing audio-related can
be verified before this exists."
```

---

### Task 3: Command protocol (pure)

**Files:**
- Create: `Sources/SpotifyRouteCore/Protocol.swift`
- Create: `Sources/SpotifyRouteTests/ProtocolTests.swift`
- Modify: `Sources/SpotifyRouteTests/main.swift`

**Interfaces:**
- Consumes: `TestRunner`, `expect`, `expectEqual` (Task 1).
- Produces: `Command` (`.on .off .toggle .status .list .selftest .use(String)`), `CommandParseError` (`.empty .unknown(String) .missingArgument(String)`), `parseCommand(_ line: String) -> Result<Command, CommandParseError>`, `encodeCommand(_ c: Command) -> String`, `Reply` (`.ok(String) .error(String)`), `encodeReply(_ r: Reply) -> String`, `parseReply(_ line: String) -> Reply`.

- [ ] **Step 1: Write the failing tests**

`Sources/SpotifyRouteTests/ProtocolTests.swift`:

```swift
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
```

Add to `Sources/SpotifyRouteTests/main.swift`, after the existing line:

```swift
failures += runProtocolTests()
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run SpotifyRouteTests`
Expected: compile failure — `cannot find 'parseCommand' in scope`.

- [ ] **Step 3: Implement**

`Sources/SpotifyRouteCore/Protocol.swift`:

```swift
import Foundation

public enum Command: Equatable, Sendable {
    case on
    case off
    case toggle
    case status
    case list
    case selftest
    case use(String)
}

public enum CommandParseError: Error, Equatable, Sendable {
    case empty
    case unknown(String)
    case missingArgument(String)
}

public enum Reply: Equatable, Sendable {
    case ok(String)
    case error(String)
}

/// Parses one line of the control protocol.
///
/// `use` is split on the first space only, so device UIDs containing spaces —
/// which real USB interfaces do have — survive intact.
public func parseCommand(_ line: String) -> Result<Command, CommandParseError> {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(.empty) }

    let verb: String
    let rest: String
    if let spaceIndex = trimmed.firstIndex(of: " ") {
        verb = String(trimmed[trimmed.startIndex..<spaceIndex])
        rest = String(trimmed[trimmed.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        verb = trimmed
        rest = ""
    }

    switch verb.lowercased() {
    case "on":       return .success(.on)
    case "off":      return .success(.off)
    case "toggle":   return .success(.toggle)
    case "status":   return .success(.status)
    case "list":     return .success(.list)
    case "selftest": return .success(.selftest)
    case "use":
        guard !rest.isEmpty else { return .failure(.missingArgument("use")) }
        return .success(.use(rest))
    default:
        return .failure(.unknown(verb))
    }
}

public func encodeCommand(_ command: Command) -> String {
    switch command {
    case .on:            return "on"
    case .off:           return "off"
    case .toggle:        return "toggle"
    case .status:        return "status"
    case .list:          return "list"
    case .selftest:      return "selftest"
    case .use(let uid):  return "use \(uid)"
    }
}

public func encodeReply(_ reply: Reply) -> String {
    switch reply {
    case .ok(let body):    return "ok \(body)"
    case .error(let body): return "error \(body)"
    }
}

/// Anything that is not a well-formed `ok ...` is surfaced as an error rather than
/// being dropped, so a protocol mismatch is visible instead of looking like success.
public func parseReply(_ line: String) -> Reply {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "ok" { return .ok("") }
    if trimmed.hasPrefix("ok ") { return .ok(String(trimmed.dropFirst(3))) }
    if trimmed.hasPrefix("error ") { return .error(String(trimmed.dropFirst(6))) }
    return .error(trimmed)
}
```

- [ ] **Step 4: Run to verify passing**

Run: `swift run SpotifyRouteTests`
Expected: `Protocol: 10 passed, 0 failed` and `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyRouteCore/Protocol.swift Sources/SpotifyRouteTests
git commit -m "Add control protocol parsing and reply encoding"
```

---

### Task 4: Settings and route status derivation (pure)

**Files:**
- Create: `Sources/SpotifyRouteCore/Settings.swift`
- Create: `Sources/SpotifyRouteTests/SettingsTests.swift`
- Modify: `Sources/SpotifyRouteTests/main.swift`

**Interfaces:**
- Consumes: `TestRunner`, `expect`, `expectEqual`, `expectNil` (Task 1).
- Produces: `Settings` (`var routeEnabled: Bool`, `var destinationUID: String?`), `RouteStatus` (`.off .active(destinationUID: String) .armed(destinationUID: String) .misconfigured(reason: String)`), `RouteStatusRule.derive(settings: Settings, isActive: Bool) -> RouteStatus`, `RouteStatus.shortLabel: String`, `SettingsStore` protocol (`load() -> Settings`, `save(_:) throws`), `FileSettingsStore(url: URL)`, `FileSettingsStore.defaultURL`.

- [ ] **Step 1: Write the failing tests**

`Sources/SpotifyRouteTests/SettingsTests.swift`:

```swift
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
```

Add to `main.swift`:

```swift
failures += runSettingsTests()
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run SpotifyRouteTests`
Expected: compile failure — `cannot find 'Settings' in scope`.

- [ ] **Step 3: Implement**

`Sources/SpotifyRouteCore/Settings.swift`:

```swift
import Foundation

/// Persisted user intent. Deliberately does not record whether the route is
/// currently running — that is runtime state, derived by RouteStatusRule.
public struct Settings: Codable, Equatable, Sendable {
    public var routeEnabled: Bool
    public var destinationUID: String?

    public init(routeEnabled: Bool = false, destinationUID: String? = nil) {
        self.routeEnabled = routeEnabled
        self.destinationUID = destinationUID
    }
}

public enum RouteStatus: Equatable, Sendable {
    case off
    /// Wanted and currently running.
    case active(destinationUID: String)
    /// Wanted, but not running — typically Spotify is not launched yet.
    case armed(destinationUID: String)
    /// Wanted, but cannot run as configured.
    case misconfigured(reason: String)

    /// Stable wire/UI label. The Stream Deck and menu bar both key off these.
    public var shortLabel: String {
        switch self {
        case .off:            return "off"
        case .active:         return "on"
        case .armed:          return "armed"
        case .misconfigured:  return "misconfigured"
        }
    }
}

public enum RouteStatusRule {
    public static func derive(settings: Settings, isActive: Bool) -> RouteStatus {
        guard settings.routeEnabled else { return .off }
        guard let uid = settings.destinationUID else {
            return .misconfigured(reason: "no destination device chosen")
        }
        return isActive ? .active(destinationUID: uid) : .armed(destinationUID: uid)
    }
}

public protocol SettingsStore {
    func load() -> Settings
    func save(_ settings: Settings) throws
}

public final class FileSettingsStore: SettingsStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("SpotifyRoute/settings.json")
    }

    /// Never throws. A missing or corrupt file yields defaults, because this is
    /// read during login and a crash there would be invisible and unrecoverable.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `swift run SpotifyRouteTests`
Expected: `Settings: 9 passed, 0 failed`, `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyRouteCore/Settings.swift Sources/SpotifyRouteTests
git commit -m "Add persisted settings and route status derivation

Route status is derived rather than stored so that persisted intent and
runtime reality cannot drift apart. Loading never throws because it runs
at login, where a crash would be both invisible and unrecoverable."
```

---

### Task 5: Core Audio support layer and output device enumeration

Device enumeration needs no audio-capture permission, so this task is verifiable by running the app binary directly with a flag.

**Files:**
- Create: `Sources/SpotifyRouteCore/CoreAudioSupport.swift`
- Create: `Sources/SpotifyRouteCore/OutputDevices.swift`
- Modify: `Sources/SpotifyRouteApp/main.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `RouteError` enum, `fourCC(_ status: OSStatus) -> String`, `CA.system`, `CA.check(_ status: OSStatus, _ what: String) throws`, `CA.string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String?`, `CA.uint32(...) -> UInt32?`, `CA.float32(...) -> Float?`, `CA.setFloat32(...) -> Bool`, `CA.setUInt32(...) -> Bool`, `CA.objectIDs(_ obj:_ selector:) throws -> [AudioObjectID]`, `OutputDevice` struct (`id`, `uid`, `name`, `sampleRate`), `OutputDevices.all() throws -> [OutputDevice]`, `OutputDevices.find(uid: String) throws -> OutputDevice?`, `OutputDevices.currentDefaultUID() -> String?`.

- [ ] **Step 1: Implement the Core Audio support layer**

`Sources/SpotifyRouteCore/CoreAudioSupport.swift`:

```swift
import Foundation
import CoreAudio

public enum RouteError: Error, CustomStringConvertible {
    case coreAudio(String, OSStatus)
    case deviceNotFound(String)
    case spotifyNotRunning
    case destinationIsDefault(String)
    case noDestinationChosen
    case selfTestFailed(String)

    public var description: String {
        switch self {
        case .coreAudio(let what, let status):
            return "\(what) failed: OSStatus \(status) \(fourCC(status))"
        case .deviceNotFound(let uid):
            return "no output device with UID \(uid)"
        case .spotifyNotRunning:
            return "Spotify is not running"
        case .destinationIsDefault(let name):
            return "\(name) is already the system default; routing it to itself only adds latency"
        case .noDestinationChosen:
            return "no destination device chosen — run 'spotroute list' then 'spotroute use <uid>'"
        case .selfTestFailed(let detail):
            return "self-test failed: \(detail)"
        }
    }
}

/// Renders an OSStatus as its four-character code when printable. Core Audio errors
/// are almost always FourCCs and are unreadable as signed decimals.
public func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                 UInt8((value >> 8) & 0xff),  UInt8(value & 0xff)]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }),
          let text = String(bytes: bytes, encoding: .ascii) else { return "" }
    return "'\(text)'"
}

public enum CA {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw RouteError.coreAudio(what, status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func string(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    public static func uint32(_ object: AudioObjectID,
                              _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> UInt32? {
        var addr = address(selector, scope, element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    public static func float32(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> Float? {
        var addr = address(selector, scope, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    public static func setFloat32(_ object: AudioObjectID,
                                  _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope,
                                  element: AudioObjectPropertyElement,
                                  _ newValue: Float) -> Bool {
        var addr = address(selector, scope, element)
        var value = Float32(newValue)
        return AudioObjectSetPropertyData(object, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    public static func setUInt32(_ object: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope,
                                 element: AudioObjectPropertyElement,
                                 _ newValue: UInt32) -> Bool {
        var addr = address(selector, scope, element)
        var value = newValue
        return AudioObjectSetPropertyData(object, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    public static func objectIDs(_ object: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size),
                  "get size of \(selector)")
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids),
                  "get \(selector)")
        return ids
    }

    /// Number of output channels across all output streams; 0 means input-only.
    public static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return (0..<list.count).reduce(0) { $0 + Int(list[$1].mNumberChannels) }
    }
}
```

- [ ] **Step 2: Implement output device enumeration**

`Sources/SpotifyRouteCore/OutputDevices.swift`:

```swift
import Foundation
import CoreAudio

public struct OutputDevice: Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double

    public init(id: AudioObjectID, uid: String, name: String, sampleRate: Double) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
    }
}

public enum OutputDevices {
    /// Every device with at least one output channel.
    public static func all() throws -> [OutputDevice] {
        try CA.objectIDs(CA.system, kAudioHardwarePropertyDevices).compactMap { id in
            guard CA.outputChannelCount(id) > 0,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  let name = CA.string(id, kAudioObjectPropertyName)
            else { return nil }
            let rate = CA.float32(id, kAudioDevicePropertyNominalSampleRate,
                                  scope: kAudioObjectPropertyScopeGlobal).map(Double.init)
            return OutputDevice(id: id, uid: uid, name: name, sampleRate: rate ?? 0)
        }
    }

    public static func find(uid: String) throws -> OutputDevice? {
        try all().first { $0.uid == uid }
    }

    /// Read ONLY so that a destination equal to the current default can be refused.
    /// The default device is never modified, and routing never depends on its identity.
    public static func currentDefaultUID() -> String? {
        guard let id = CA.uint32(CA.system, kAudioHardwarePropertyDefaultOutputDevice)
        else { return nil }
        return CA.string(AudioObjectID(id), kAudioDevicePropertyDeviceUID)
    }
}
```

- [ ] **Step 3: Add a `--list-devices` path to the app for verification**

Replace `Sources/SpotifyRouteApp/main.swift`:

```swift
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
```

- [ ] **Step 4: Build and verify against real hardware**

```bash
swift build
swift run SpotifyRouteApp --list-devices
```

Expected: every output device listed with UID and sample rate, exactly one marked `(system default)`. Input-only devices (for example a microphone) must **not** appear. Confirm the machine's built-in speakers and any USB interface are present.

- [ ] **Step 5: Verify the test suite still passes**

Run: `swift run SpotifyRouteTests`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpotifyRouteCore/CoreAudioSupport.swift \
        Sources/SpotifyRouteCore/OutputDevices.swift \
        Sources/SpotifyRouteApp/main.swift
git commit -m "Add Core Audio support layer and output device enumeration

Devices are identified by UID rather than name throughout, since names
collide across identical hardware and change with firmware. The default
device is read in exactly one place, solely to refuse routing a device
to itself."
```

---

### Task 6: Spotify process lookup, AudioRouter, and the on-hardware self-test

The core of the project. Everything here must run inside the signed bundle from Task 2 or it will silently produce zeroed audio.

**Files:**
- Create: `Sources/SpotifyRouteCore/SpotifyProcess.swift`
- Create: `Sources/SpotifyRouteCore/AudioRouter.swift`
- Create: `Sources/SpotifyRouteCore/SelfTest.swift`
- Modify: `Sources/SpotifyRouteApp/main.swift`

**Interfaces:**
- Consumes: `RouteError`, `CA.*`, `OutputDevice`, `OutputDevices` (Task 5).
- Produces: `SpotifyProcess.bundleID`, `SpotifyProcess.processObject() throws -> AudioObjectID`, `SpotifyProcess.isProducingOutput(_ object: AudioObjectID) -> Bool`, `AudioRouter()`, `AudioRouter.isActive: Bool`, `AudioRouter.activeDestinationUID: String?`, `AudioRouter.enable(destination: OutputDevice, processObject: AudioObjectID) throws`, `AudioRouter.disable()`, `AudioRouter.statistics() -> (callbacks: Int, peak: Float)`, `SelfTest.Outcome` struct, `SelfTest.run(destination: OutputDevice, seconds: Double) throws -> SelfTest.Outcome`.

- [ ] **Step 1: Implement Spotify process lookup**

`Sources/SpotifyRouteCore/SpotifyProcess.swift`:

```swift
import Foundation
import AppKit
import CoreAudio

public enum SpotifyProcess {
    public static let bundleID = "com.spotify.client"

    public static func processObject() throws -> AudioObjectID {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier > 0 })
        else { throw RouteError.spotifyNotRunning }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = app.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try CA.check(AudioObjectGetPropertyData(CA.system, &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object),
                     "translate Spotify pid \(pid) to process object")
        guard object != AudioObjectID(kAudioObjectUnknown) else {
            throw RouteError.spotifyNotRunning
        }
        return object
    }

    /// True while the process holds an active output stream. A fully paused Spotify
    /// releases its stream, and the tap then legitimately produces no callbacks.
    public static func isProducingOutput(_ object: AudioObjectID) -> Bool {
        CA.uint32(object, kAudioProcessPropertyIsRunningOutput) == 1
    }
}
```

- [ ] **Step 2: Implement AudioRouter using the verified recipe**

`Sources/SpotifyRouteCore/AudioRouter.swift`:

```swift
import Foundation
import CoreAudio
import AudioToolbox

/// Owns every Core Audio object involved in a route: the process tap, the private
/// aggregate device wrapping the destination, and the IOProc copying one to the other.
///
/// The recipe here was established by measurement and should not be altered without
/// re-measuring. In particular `.mutedWhenTapped` is what *moves* the app's audio
/// rather than duplicating it, and the destination must be the aggregate's main
/// sub-device so that both ends share one clock domain and need no resampling.
public final class AudioRouter {
    /// Callback-shared state, guarded by a lock rather than actor isolation because
    /// the IOProc runs on a Core Audio real-time thread.
    private final class Metrics {
        private let lock = NSLock()
        private var callbacks = 0
        private var peak: Float = 0
        func record(peak newPeak: Float) {
            lock.lock(); callbacks += 1; peak = max(peak, newPeak); lock.unlock()
        }
        func snapshot() -> (Int, Float) {
            lock.lock(); defer { peak = 0; lock.unlock() }; return (callbacks, peak)
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var metrics = Metrics()

    public private(set) var activeDestinationUID: String?
    public var isActive: Bool { ioProcID != nil }

    public init() {}

    public func enable(destination: OutputDevice, processObject: AudioObjectID) throws {
        if isActive {
            if activeDestinationUID == destination.uid { return }  // idempotent
            disable()                                              // destination changed
        }

        // --- the tap ---
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "SpotifyRoute"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            // Opportunistic: lets the OS reattach the tap when Spotify relaunches.
            // Never relied upon, since the supported floor is 14.2.
            description.isProcessRestoreEnabled = true
        }

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateProcessTap(description, &newTap),
                     "AudioHardwareCreateProcessTap")
        tapID = newTap

        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            disable()
            throw RouteError.coreAudio("read tap UID", OSStatus(-1))
        }

        // --- the aggregate: destination is clock master, tap is the input ---
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpotifyRoute",
            kAudioAggregateDeviceUIDKey: "com.italo.spotifyroute.aggregate.\(getpid())",
            kAudioAggregateDeviceMainSubDeviceKey: destination.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: destination.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &newAggregate),
                     "AudioHardwareCreateAggregateDevice")
        aggregateID = newAggregate

        // --- the IOProc ---
        let metrics = Metrics()
        self.metrics = metrics
        var newProc: AudioDeviceIOProcID?
        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)

            // Zero every output buffer first, so any buffer the tap does not fill
            // emits silence rather than whatever was left in it.
            for i in 0..<outputs.count {
                if let data = outputs[i].mData {
                    memset(data, 0, Int(outputs[i].mDataByteSize))
                }
            }
            var peak: Float = 0
            for i in 0..<min(inputs.count, outputs.count) {
                guard let source = inputs[i].mData, let dest = outputs[i].mData else { continue }
                let bytes = min(inputs[i].mDataByteSize, outputs[i].mDataByteSize)
                memcpy(dest, source, Int(bytes))
                let sampleCount = Int(bytes) / MemoryLayout<Float>.size
                let samples = source.assumingMemoryBound(to: Float.self)
                for s in 0..<sampleCount { peak = max(peak, abs(samples[s])) }
            }
            metrics.record(peak: peak)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = newProc

        try CA.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        activeDestinationUID = destination.uid
    }

    /// Safe to call at any time, including part-way through a failed enable().
    public func disable() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        activeDestinationUID = nil
    }

    public func statistics() -> (callbacks: Int, peak: Float) {
        let (callbacks, peak) = metrics.snapshot()
        return (callbacks, peak)
    }
}
```

- [ ] **Step 3: Implement the self-test**

`Sources/SpotifyRouteCore/SelfTest.swift`:

```swift
import Foundation
import CoreAudio

/// Verifies the whole routing path against real hardware using a process whose audio
/// we control, so a pass means "audio measurably flowed" rather than "no error was
/// returned". This exists because a tap outside a signed .app bundle returns perfectly
/// well-formed buffers of pure silence with no error at all — the single most
/// misleading failure mode in this project.
public enum SelfTest {
    public struct Outcome: Sendable {
        public let callbacks: Int
        public let peak: Float
        public let passed: Bool
        public let detail: String
    }

    public static func run(destination: OutputDevice, seconds: Double = 3) throws -> Outcome {
        let toneURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spotifyroute-selftest-\(getpid()).wav")
        try writeSineWAV(to: toneURL, seconds: seconds + 4, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [toneURL.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }

        // Wait for the player to actually hold an output stream.
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = player.processIdentifier
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var ready = false
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if AudioObjectGetPropertyData(CA.system, &addr,
                                          UInt32(MemoryLayout<pid_t>.size), &pid,
                                          &size, &processObject) == noErr,
               processObject != AudioObjectID(kAudioObjectUnknown),
               SpotifyProcess.isProducingOutput(processObject) {
                ready = true
                break
            }
        }
        guard ready else {
            throw RouteError.selfTestFailed("the test tone process never produced output")
        }

        let router = AudioRouter()
        try router.enable(destination: destination, processObject: processObject)
        defer { router.disable() }

        Thread.sleep(forTimeInterval: seconds)
        let (callbacks, peak) = router.statistics()

        if callbacks == 0 {
            return Outcome(callbacks: 0, peak: 0, passed: false,
                           detail: "no IOProc callbacks — the aggregate never ran")
        }
        if peak <= 0.001 {
            return Outcome(callbacks: callbacks, peak: peak, passed: false,
                           detail: "callbacks ran but every sample was silent — this almost "
                                 + "always means the audio-capture permission is missing. "
                                 + "Confirm the binary is running from the signed .app "
                                 + "bundle and that Privacy settings allow audio recording.")
        }
        return Outcome(callbacks: callbacks, peak: peak, passed: true,
                       detail: "routed \(callbacks) buffers to \(destination.name), peak \(peak)")
    }

    /// Minimal 16-bit stereo PCM WAV writer — avoids depending on AVFoundation
    /// for what is a few dozen bytes of header.
    static func writeSineWAV(to url: URL, seconds: Double, amplitude: Double) throws {
        let sampleRate = 48_000
        let frequency = 440.0
        let frameCount = Int(Double(sampleRate) * seconds)
        var samples = Data(capacity: frameCount * 4)
        for n in 0..<frameCount {
            let value = Int16(amplitude * 32_767.0
                              * sin(2.0 * Double.pi * frequency * Double(n) / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }

        var file = Data()
        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }

        file.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + samples.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE32(16)                              // fmt chunk size
        appendLE16(1)                               // PCM
        appendLE16(2)                               // stereo
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 4))          // byte rate
        appendLE16(4)                               // block align
        appendLE16(16)                              // bits per sample
        file.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(samples.count))
        file.append(samples)

        try file.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Add a `--selftest` path to the app**

Insert into `Sources/SpotifyRouteApp/main.swift`, before the final `print`:

```swift
if args.first == "--selftest" {
    // Second argument is an optional destination UID; defaults to built-in speakers.
    do {
        let devices = try OutputDevices.all()
        let requested = args.count > 1 ? args[1] : nil
        guard let destination = requested.flatMap({ uid in devices.first { $0.uid == uid } })
                ?? devices.first(where: { $0.uid == "BuiltInSpeakerDevice" })
                ?? devices.first
        else {
            print("no output devices available")
            exit(1)
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
```

- [ ] **Step 5: Demonstrate the unbundled failure mode deliberately**

```bash
swift build
swift run SpotifyRouteApp --selftest
```

Expected: **FAIL**, reporting callbacks but silent samples. This is correct and important — it confirms the permission boundary is real and that the self-test detects it. Do not try to fix this.

- [ ] **Step 6: Run the same code from the signed bundle**

```bash
./build.sh
./build/SpotifyRoute.app/Contents/MacOS/SpotifyRouteApp --selftest
```

Expected: **PASS**, with `peak` near `0.25` — the amplitude the tone was generated at. A quiet 440 Hz tone is audible for ~3 seconds.

If this reports silence, the audio-capture permission is the likely cause — but the bundled-vs-unbundled boundary could not be reproduced in the development environment (see Task 15 Step 0), so verify rather than assume.

- [ ] **Step 7: Verify unit tests still pass**

Run: `swift run SpotifyRouteTests`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 8: Commit**

```bash
git add Sources/SpotifyRouteCore/SpotifyProcess.swift \
        Sources/SpotifyRouteCore/AudioRouter.swift \
        Sources/SpotifyRouteCore/SelfTest.swift \
        Sources/SpotifyRouteApp/main.swift
git commit -m "Add process tap routing and an on-hardware self-test

The self-test asserts measured non-zero output rather than merely a
successful return, because a tap outside a signed bundle yields
well-formed buffers of pure silence with no error. Running --selftest
unbundled fails and bundled passes; that contrast is the check."
```

---

### Task 7: Destination audibility (mute and volume floor)

**Files:**
- Create: `Sources/SpotifyRouteCore/DestinationAudibility.swift`
- Modify: `Sources/SpotifyRouteApp/main.swift`

**Interfaces:**
- Consumes: `CA.*`, `OutputDevice` (Task 5), `VolumeFloorRule` (Task 1).
- Produces: `Audibility` protocol (`prepare(_ device: OutputDevice)`, `restore(_ device: OutputDevice)`), `DestinationAudibility` conforming to it, `DestinationAudibility.readVolume(_ device: AudioObjectID) -> Float?`, `DestinationAudibility.readMute(_ device: AudioObjectID) -> UInt32?`.

- [ ] **Step 1: Implement**

`Sources/SpotifyRouteCore/DestinationAudibility.swift`:

```swift
import Foundation
import CoreAudio

public protocol Audibility: AnyObject {
    func prepare(_ device: OutputDevice)
    func restore(_ device: OutputDevice)
}

/// Makes a destination device actually audible, and puts back what it changed.
///
/// This is a correctness requirement, not a convenience. A device that is not the
/// system default keeps its own volume and mute state, which the keyboard volume keys
/// never touch. During development the first audible test failed entirely because the
/// destination was muted at the device level while reporting volume 1.000 — the audio
/// was routed perfectly and inaudibly.
public final class DestinationAudibility: Audibility {
    /// Prior mute value per device UID, so restore() can put back exactly what it found.
    private var priorMute: [String: UInt32] = [:]

    public init() {}

    public func prepare(_ device: OutputDevice) {
        if let existing = Self.readMute(device.id) {
            priorMute[device.uid] = existing
        }
        _ = Self.writeMute(device.id, 0)

        // Raise the volume only if it is inaudible; never lower an audible one.
        if let target = VolumeFloorRule.desiredVolume(current: Self.readVolume(device.id)) {
            _ = Self.writeVolume(device.id, target)
        }
    }

    /// Restores the prior *mute* state only. The prior volume is deliberately not
    /// restored: if the user adjusted the volume while listening, putting the old
    /// value back would silently undo their change.
    public func restore(_ device: OutputDevice) {
        if let prior = priorMute.removeValue(forKey: device.uid) {
            _ = Self.writeMute(device.id, prior)
        }
    }

    // Devices expose volume and mute on either the main element or per channel;
    // try main first, then channels 1 and 2.
    public static func readVolume(_ device: AudioObjectID) -> Float? {
        if let v = CA.float32(device, kAudioDevicePropertyVolumeScalar,
                              scope: kAudioDevicePropertyScopeOutput,
                              element: kAudioObjectPropertyElementMain) { return v }
        for channel in UInt32(1)...2 {
            if let v = CA.float32(device, kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioDevicePropertyScopeOutput,
                                  element: channel) { return v }
        }
        return nil
    }

    static func writeVolume(_ device: AudioObjectID, _ value: Float) -> Bool {
        var wrote = CA.setFloat32(device, kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioDevicePropertyScopeOutput,
                                  element: kAudioObjectPropertyElementMain, value)
        for channel in UInt32(1)...2 {
            if CA.setFloat32(device, kAudioDevicePropertyVolumeScalar,
                             scope: kAudioDevicePropertyScopeOutput,
                             element: channel, value) { wrote = true }
        }
        return wrote
    }

    public static func readMute(_ device: AudioObjectID) -> UInt32? {
        if let m = CA.uint32(device, kAudioDevicePropertyMute,
                             scope: kAudioDevicePropertyScopeOutput,
                             element: kAudioObjectPropertyElementMain) { return m }
        for channel in UInt32(1)...2 {
            if let m = CA.uint32(device, kAudioDevicePropertyMute,
                                 scope: kAudioDevicePropertyScopeOutput,
                                 element: channel) { return m }
        }
        return nil
    }

    static func writeMute(_ device: AudioObjectID, _ value: UInt32) -> Bool {
        var wrote = CA.setUInt32(device, kAudioDevicePropertyMute,
                                 scope: kAudioDevicePropertyScopeOutput,
                                 element: kAudioObjectPropertyElementMain, value)
        for channel in UInt32(1)...2 {
            if CA.setUInt32(device, kAudioDevicePropertyMute,
                            scope: kAudioDevicePropertyScopeOutput,
                            element: channel, value) { wrote = true }
        }
        return wrote
    }
}
```

- [ ] **Step 2: Add a `--show-audibility` diagnostic to the app**

Insert into `Sources/SpotifyRouteApp/main.swift` before the final `print`:

```swift
if args.first == "--show-audibility" {
    do {
        for device in try OutputDevices.all() {
            let volume = DestinationAudibility.readVolume(device.id)
            let mute = DestinationAudibility.readMute(device.id)
            let volumeText = volume.map { String(format: "%.3f", $0) } ?? "n/a"
            let muteText = mute.map { $0 == 1 ? "MUTED" : "unmuted" } ?? "n/a"
            print("\(device.name): volume=\(volumeText) \(muteText)")
        }
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
```

- [ ] **Step 3: Verify against hardware**

```bash
swift build
swift run SpotifyRouteApp --show-audibility
```

Expected: each output device with a volume and mute state. This is the diagnostic that would have explained the silent first test immediately, so confirm it reports a plausible value for the built-in speakers.

- [ ] **Step 4: Verify the volume rule tests still pass**

Run: `swift run SpotifyRouteTests`
Expected: `ALL TESTS PASSED` — `VolumeFloorRule` still covers the decision logic; this task only wires it to hardware.

- [ ] **Step 5: Commit**

```bash
git add Sources/SpotifyRouteCore/DestinationAudibility.swift Sources/SpotifyRouteApp/main.swift
git commit -m "Add destination mute and volume-floor handling

A non-default output device keeps its own volume and mute state that the
volume keys never reach, so a perfectly routed stream can be completely
inaudible. Restores the prior mute state but deliberately not the prior
volume, so a volume the user changed while listening is not undone."
```

---

### Task 8: RouteController — command semantics with fakes

All command meaning lives here, behind protocols, so it is genuinely unit-testable without hardware. This is where logic bugs would otherwise hide.

**Files:**
- Create: `Sources/SpotifyRouteCore/RouteController.swift`
- Create: `Sources/SpotifyRouteTests/RouteControllerTests.swift`
- Modify: `Sources/SpotifyRouteCore/AudioRouter.swift` (add `Routing` conformance)
- Modify: `Sources/SpotifyRouteCore/OutputDevices.swift` (add `DeviceListing` conformance)
- Modify: `Sources/SpotifyRouteCore/SpotifyProcess.swift` (add `ProcessLocating` conformance)
- Modify: `Sources/SpotifyRouteTests/main.swift`

**Interfaces:**
- Consumes: `Settings`, `SettingsStore`, `RouteStatus`, `RouteStatusRule` (Task 4); `OutputDevice` (Task 5); `Audibility` (Task 7); `Command`, `Reply` (Task 3).
- Produces: `Routing`, `DeviceListing`, `ProcessLocating` protocols; `LiveDeviceListing`, `LiveProcessLocating` concrete types; `RouteController(store:router:devices:processes:audibility:)`, `RouteController.handle(_ command: Command) -> Reply`, `RouteController.status: RouteStatus`, `RouteController.reapply()`, `RouteController.shutdown()`.

- [ ] **Step 1: Write the failing tests**

`Sources/SpotifyRouteTests/RouteControllerTests.swift`:

```swift
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
        let (c, _, router, _, _, _) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)
        let devices = FakeDevices()
        devices.defaultUID = "SPEAKERS"          // interface is now free to be a destination
        let (c2, _, router2, _, _, _) = makeController(devices: devices)
        _ = c2.handle(.use("IFACE"))
        _ = c2.handle(.on)
        try expectEqual(router2.enableCalls, ["IFACE"])
        try expectEqual(router.enableCalls, ["SPEAKERS"])
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
        let (c, _, _, _, _, _) = makeController()
        _ = c.handle(.use("SPEAKERS"))
        _ = c.handle(.on)
        guard case .ok(let body) = c.handle(.status) else { throw TestFailure("expected ok") }
        try expect(body.contains("on"), "includes the state")
        try expect(body.contains("Built-in Speakers"), "includes a human-readable name")
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

    return r.summarise()
}
```

Add to `main.swift`:

```swift
failures += runRouteControllerTests()
```

- [ ] **Step 2: Run to verify failure**

Run: `swift run SpotifyRouteTests`
Expected: compile failure — `cannot find 'RouteController' in scope` and `cannot find type 'Routing' in scope`.

- [ ] **Step 3: Implement the protocols and conformances**

Append to `Sources/SpotifyRouteCore/AudioRouter.swift`:

```swift
/// Abstracts the routing hardware so command semantics can be tested without it.
public protocol Routing: AnyObject {
    var isActive: Bool { get }
    var activeDestinationUID: String? { get }
    func enable(destination: OutputDevice, processObject: AudioObjectID) throws
    func disable()
}

extension AudioRouter: Routing {}
```

Append to `Sources/SpotifyRouteCore/OutputDevices.swift`:

```swift
public protocol DeviceListing {
    func allOutputDevices() throws -> [OutputDevice]
    func currentDefaultUID() -> String?
}

public struct LiveDeviceListing: DeviceListing {
    public init() {}
    public func allOutputDevices() throws -> [OutputDevice] { try OutputDevices.all() }
    public func currentDefaultUID() -> String? { OutputDevices.currentDefaultUID() }
}
```

Append to `Sources/SpotifyRouteCore/SpotifyProcess.swift`:

```swift
public protocol ProcessLocating {
    func spotifyProcessObject() throws -> AudioObjectID
}

public struct LiveProcessLocating: ProcessLocating {
    public init() {}
    public func spotifyProcessObject() throws -> AudioObjectID {
        try SpotifyProcess.processObject()
    }
}
```

- [ ] **Step 4: Implement RouteController**

`Sources/SpotifyRouteCore/RouteController.swift`:

```swift
import Foundation
import CoreAudio

/// Holds all command semantics. Depends only on protocols so it is unit-testable
/// without any audio hardware, which matters because this is where the interesting
/// decisions live: refusing a self-route, arming when Spotify is absent, and never
/// persisting an intent that failed to apply.
public final class RouteController {
    private let store: SettingsStore
    private let router: Routing
    private let devices: DeviceListing
    private let processes: ProcessLocating
    private let audibility: Audibility

    private var settings: Settings

    public init(store: SettingsStore,
                router: Routing,
                devices: DeviceListing,
                processes: ProcessLocating,
                audibility: Audibility) {
        self.store = store
        self.router = router
        self.devices = devices
        self.processes = processes
        self.audibility = audibility
        self.settings = store.load()
    }

    public var status: RouteStatus {
        RouteStatusRule.derive(settings: settings, isActive: router.isActive)
    }

    /// The persisted destination, exposed so UI can show a checkmark without having to
    /// parse a display string back into a UID.
    public var destinationUID: String? { settings.destinationUID }

    public func handle(_ command: Command) -> Reply {
        switch command {
        case .list:     return handleList()
        case .use(let uid): return handleUse(uid)
        case .on:       return handleOn()
        case .off:      return handleOff()
        case .toggle:   return settings.routeEnabled ? handleOff() : handleOn()
        case .status:   return handleStatus()
        case .selftest: return handleSelfTest()
        }
    }

    // MARK: - commands

    private func handleList() -> Reply {
        do {
            let all = try devices.allOutputDevices()
            let defaultUID = devices.currentDefaultUID()
            let lines = all.map { device -> String in
                var flags: [String] = []
                if device.uid == defaultUID { flags.append("system default") }
                if device.uid == settings.destinationUID { flags.append("chosen destination") }
                let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
                return "\(device.name)\(suffix)\n    \(device.uid)"
            }
            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .error("\(error)")
        }
    }

    private func handleUse(_ uid: String) -> Reply {
        do {
            let all = try devices.allOutputDevices()
            guard let device = all.first(where: { $0.uid == uid }) else {
                return .error("\(RouteError.deviceNotFound(uid))")
            }
            if uid == devices.currentDefaultUID() {
                return .error("\(RouteError.destinationIsDefault(device.name))")
            }
            settings.destinationUID = uid
            try store.save(settings)
            // If a route is already running, move it to the new destination.
            if settings.routeEnabled, router.isActive {
                return handleOn()
            }
            return .ok("destination set to \(device.name)")
        } catch {
            return .error("\(error)")
        }
    }

    private func handleOn() -> Reply {
        guard let uid = settings.destinationUID else {
            return .error("\(RouteError.noDestinationChosen)")
        }
        let device: OutputDevice
        do {
            guard let found = try devices.allOutputDevices().first(where: { $0.uid == uid })
            else { return .error("\(RouteError.deviceNotFound(uid))") }
            device = found
        } catch {
            return .error("\(error)")
        }

        // Spotify absent is not a failure: remember the intent and apply on launch.
        let processObject: AudioObjectID
        do {
            processObject = try processes.spotifyProcessObject()
        } catch {
            settings.routeEnabled = true
            try? store.save(settings)
            return .ok(RouteStatus.armed(destinationUID: uid).shortLabel)
        }

        do {
            audibility.prepare(device)
            try router.enable(destination: device, processObject: processObject)
        } catch {
            // Do not persist an intent that could not be applied.
            audibility.restore(device)
            return .error("\(error)")
        }

        settings.routeEnabled = true
        try? store.save(settings)
        return .ok(RouteStatus.active(destinationUID: uid).shortLabel)
    }

    private func handleOff() -> Reply {
        router.disable()
        if let uid = settings.destinationUID,
           let device = try? devices.allOutputDevices().first(where: { $0.uid == uid }) {
            audibility.restore(device)
        }
        settings.routeEnabled = false
        try? store.save(settings)
        return .ok(RouteStatus.off.shortLabel)
    }

    private func handleStatus() -> Reply {
        let name = settings.destinationUID
            .flatMap { uid in try? devices.allOutputDevices().first { $0.uid == uid } }
            .map(\.name)
        switch status {
        case .off:
            return .ok("off" + (name.map { " (destination: \($0))" } ?? ""))
        case .active:
            return .ok("on -> \(name ?? "unknown device")")
        case .armed:
            return .ok("armed -> \(name ?? "unknown device") (waiting for Spotify)")
        case .misconfigured(let reason):
            return .ok("misconfigured: \(reason)")
        }
    }

    private func handleSelfTest() -> Reply {
        guard let uid = settings.destinationUID,
              let device = try? devices.allOutputDevices().first(where: { $0.uid == uid })
        else { return .error("\(RouteError.noDestinationChosen)") }
        do {
            let outcome = try SelfTest.run(destination: device, seconds: 3)
            return outcome.passed
                ? .ok("selftest passed — \(outcome.detail)")
                : .error("selftest failed — \(outcome.detail)")
        } catch {
            return .error("\(error)")
        }
    }

    // MARK: - lifecycle

    /// Applies a persisted-but-inactive route. Called when Spotify launches and on the
    /// isRunningOutput 0->1 edge.
    public func reapply() {
        guard settings.routeEnabled, !router.isActive else { return }
        _ = handleOn()
    }

    /// Tears down audio objects without changing persisted intent, so the route comes
    /// back on next launch.
    public func shutdown() {
        router.disable()
        if let uid = settings.destinationUID,
           let device = try? devices.allOutputDevices().first(where: { $0.uid == uid }) {
            audibility.restore(device)
        }
    }
}
```

- [ ] **Step 5: Run to verify passing**

Run: `swift run SpotifyRouteTests`
Expected: `RouteController: 15 passed, 0 failed` and `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpotifyRouteCore Sources/SpotifyRouteTests
git commit -m "Add RouteController holding all command semantics

Depends only on protocols so the interesting decisions are unit-tested
without hardware: refusing to route a device to itself, arming rather
than failing when Spotify is absent, and never persisting an intent that
failed to apply."
```

---

### Task 9: CommandServer — Unix domain socket

**Files:**
- Create: `Sources/SpotifyRouteCore/CommandServer.swift`

**Interfaces:**
- Consumes: `Command`, `Reply`, `parseCommand`, `encodeReply` (Task 3).
- Produces: `CommandServer(socketURL: URL, handler: @escaping (Command) -> Reply)`, `CommandServer.start() throws`, `CommandServer.stop()`, `CommandServer.defaultSocketURL: URL`.

Protocol shape: the client sends one line and the server writes a reply — which may span several lines, as `list` does — then closes the connection. The client reads until EOF. Framing by connection close rather than by line keeps multi-line replies trivial.

- [ ] **Step 1: Implement**

`Sources/SpotifyRouteCore/CommandServer.swift`:

```swift
import Foundation

/// Accepts commands over a Unix domain socket.
///
/// A socket rather than a custom URL scheme because LaunchServices registration for an
/// ad-hoc-signed app outside /Applications is unreliable; and rather than HTTP because
/// this needs no port allocation and is not reachable from off the machine.
public final class CommandServer {
    private let socketURL: URL
    private let handler: (Command) -> Reply
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var stopping = false

    public init(socketURL: URL, handler: @escaping (Command) -> Reply) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public static var defaultSocketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("SpotifyRoute/control.sock")
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A stale socket file from a crash would make bind() fail with EADDRINUSE.
        unlink(socketURL.path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw RouteError.coreAudio("socket()", OSStatus(errno))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw RouteError.selfTestFailed("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0 else {
            close(listenFD)
            throw RouteError.selfTestFailed("bind() failed: errno \(errno)")
        }
        guard listen(listenFD, 8) == 0 else {
            close(listenFD)
            throw RouteError.selfTestFailed("listen() failed: errno \(errno)")
        }

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "SpotifyRoute.CommandServer"
        t.start()
        thread = t
    }

    public func stop() {
        stopping = true
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketURL.path)
    }

    private func acceptLoop() {
        while !stopping {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if stopping { return }
                continue
            }
            serve(clientFD)
            close(clientFD)
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0,
              let line = String(bytes: buffer[0..<count], encoding: .utf8)
        else { return }

        let reply: Reply
        switch parseCommand(line) {
        case .success(let command):
            // Core Audio work is serialised onto the main thread; the app's run loop
            // is never blocked for long, so this cannot deadlock in practice.
            var result: Reply = .error("no reply")
            if Thread.isMainThread {
                result = handler(command)
            } else {
                DispatchQueue.main.sync { result = handler(command) }
            }
            reply = result
        case .failure(let error):
            switch error {
            case .empty:
                reply = .error("empty command")
            case .unknown(let verb):
                reply = .error("unknown command '\(verb)' — try on, off, toggle, status, list, use <uid>, selftest")
            case .missingArgument(let verb):
                reply = .error("'\(verb)' needs an argument, e.g. use <device-uid>")
            }
        }

        let payload = encodeReply(reply) + "\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Verify unit tests still pass**

Run: `swift run SpotifyRouteTests`
Expected: `ALL TESTS PASSED`

- [ ] **Step 4: Commit**

```bash
git add Sources/SpotifyRouteCore/CommandServer.swift
git commit -m "Add Unix domain socket command server

Replies are framed by connection close rather than newline so multi-line
replies like 'list' need no escaping. Stale socket files from a crash are
unlinked before bind, which would otherwise fail with EADDRINUSE."
```

---

### Task 10: The `spotroute` CLI

**Files:**
- Modify: `Sources/spotroute/main.swift`

**Interfaces:**
- Consumes: `encodeCommand`, `parseCommand`, `parseReply`, `Reply` (Task 3); `CommandServer.defaultSocketURL` (Task 9).
- Produces: the `spotroute` executable. Exit code 0 on `ok`, 1 on `error` or connection failure — so a Stream Deck or shell caller can branch on it.

- [ ] **Step 1: Implement**

Replace `Sources/spotroute/main.swift`:

```swift
import Foundation
import SpotifyRouteCore

// A thin socket client. It deliberately contains no Core Audio code at all: a process
// tap outside a signed .app bundle silently returns zeroed audio, so all audio work
// belongs to the bundled app. This binary only asks the app to do things.

let usage = """
spotroute — control SpotifyRoute

  spotroute on              route Spotify to the chosen destination
  spotroute off             send Spotify back to the system default
  spotroute toggle          flip between the two
  spotroute status          show current state
  spotroute list            list available output devices
  spotroute use <uid>       choose the destination device
  spotroute selftest        verify audio really flows (uses the app's permission)

Stream Deck: use a Multi Action Switch whose two states run
'spotroute on' and 'spotroute off', so the key icon tracks the real state.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    print(usage)
    exit(2)
}
if arguments.first == "-h" || arguments.first == "--help" {
    print(usage)
    exit(0)
}

// Validate locally so a typo does not need a round trip.
let line = arguments.joined(separator: " ")
if case .failure(let error) = parseCommand(line) {
    switch error {
    case .empty:
        FileHandle.standardError.write("error: empty command\n".data(using: .utf8)!)
    case .unknown(let verb):
        FileHandle.standardError.write("error: unknown command '\(verb)'\n\n\(usage)\n"
            .data(using: .utf8)!)
    case .missingArgument(let verb):
        FileHandle.standardError.write("error: '\(verb)' needs an argument\n\n\(usage)\n"
            .data(using: .utf8)!)
    }
    exit(2)
}

let socketPath = CommandServer.defaultSocketURL.path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    FileHandle.standardError.write("error: could not create socket\n".data(using: .utf8)!)
    exit(1)
}
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    socketPath.utf8.enumerated().forEach { raw[$0.offset] = $0.element }
}
let size = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
}
guard connected == 0 else {
    FileHandle.standardError.write("""
        error: SpotifyRoute is not running (no socket at \(socketPath))

        Start it with:  open /Applications/SpotifyRoute.app
        or from a build: open ./build/SpotifyRoute.app

        """.data(using: .utf8)!)
    exit(1)
}

_ = (line + "\n").withCString { write(fd, $0, strlen($0)) }

var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let count = read(fd, &buffer, buffer.count)
    if count <= 0 { break }
    response.append(contentsOf: buffer[0..<count])
}

let text = String(data: response, encoding: .utf8) ?? ""
switch parseReply(text) {
case .ok(let body):
    if !body.isEmpty { print(body) }
    exit(0)
case .error(let body):
    FileHandle.standardError.write("error: \(body)\n".data(using: .utf8)!)
    exit(1)
}
```

- [ ] **Step 2: Verify the offline behaviour**

```bash
swift build
swift run spotroute
swift run spotroute status
```

Expected: bare invocation prints usage and exits 2. `status` fails with the "SpotifyRoute is not running" message and exit 1, because no app is listening yet. Both are correct at this stage.

- [ ] **Step 3: Verify local validation rejects typos without a round trip**

Run: `swift run spotroute frobnicate`
Expected: `error: unknown command 'frobnicate'` plus usage, exit 2 — and no socket error, proving it was caught locally.

- [ ] **Step 4: Commit**

```bash
git add Sources/spotroute/main.swift
git commit -m "Add spotroute CLI

Contains no Core Audio code by design: an unbundled binary cannot get
audio-capture permission, so it only asks the bundled app to act. Exit
codes distinguish ok from error so shell and Stream Deck callers can branch."
```

---

### Task 11: SpotifyWatcher — launch, quit, and playback edges

**Files:**
- Create: `Sources/SpotifyRouteCore/SpotifyWatcher.swift`

**Interfaces:**
- Consumes: `SpotifyProcess` (Task 6).
- Produces: `SpotifyWatcher(onAppeared:onVanished:onPlaybackStarted:)`, `SpotifyWatcher.start()`, `SpotifyWatcher.stop()`.

- [ ] **Step 1: Implement**

`Sources/SpotifyRouteCore/SpotifyWatcher.swift`:

```swift
import Foundation
import AppKit
import CoreAudio

/// Watches Spotify so an armed route applies itself without user action.
///
/// Two mechanisms, because they cover different cases:
///   - NSWorkspace notifications react immediately to launch and quit.
///   - A poll detects the isRunningOutput 0->1 edge, i.e. the user pressing play
///     after a fully paused Spotify released its output stream. Polling rather than a
///     property listener because the process object is only obtainable while the app
///     exists, so there is nothing stable to attach a listener to across relaunches.
public final class SpotifyWatcher {
    private let onAppeared: () -> Void
    private let onVanished: () -> Void
    private let onPlaybackStarted: () -> Void

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var wasProducingOutput = false

    /// 2s is a deliberate compromise: fast enough that pressing play feels immediate,
    /// slow enough to be invisible in CPU use.
    private let pollInterval: TimeInterval = 2.0

    public init(onAppeared: @escaping () -> Void,
                onVanished: @escaping () -> Void,
                onPlaybackStarted: @escaping () -> Void) {
        self.onAppeared = onAppeared
        self.onVanished = onVanished
        self.onPlaybackStarted = onPlaybackStarted
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier == SpotifyProcess.bundleID else { return }
            self?.onAppeared()
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.bundleIdentifier == SpotifyProcess.bundleID else { return }
            self?.wasProducingOutput = false
            self?.onVanished()
        })

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    private func poll() {
        guard let object = try? SpotifyProcess.processObject() else {
            wasProducingOutput = false
            return
        }
        let producing = SpotifyProcess.isProducingOutput(object)
        if producing && !wasProducingOutput {
            onPlaybackStarted()
        }
        wasProducingOutput = producing
    }
}
```

- [ ] **Step 2: Build and verify tests**

```bash
swift build
swift run SpotifyRouteTests
```

Expected: build succeeds, `ALL TESTS PASSED`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SpotifyRouteCore/SpotifyWatcher.swift
git commit -m "Add Spotify launch, quit and playback-start observation

NSWorkspace notifications cover launch and quit; a 2s poll covers the
isRunningOutput 0->1 edge, since the process object only exists while
Spotify does and offers nothing stable to attach a listener to across
relaunches."
```

---

### Task 12: Menu bar app

**Files:**
- Create: `Sources/SpotifyRouteApp/MenuBarController.swift`
- Modify: `Sources/SpotifyRouteApp/main.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–11.
- Produces: the working menu-bar application.

- [ ] **Step 1: Implement the menu bar controller**

`Sources/SpotifyRouteApp/MenuBarController.swift`:

```swift
import AppKit
import SpotifyRouteCore

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: RouteController
    private let devices: DeviceListing

    init(controller: RouteController, devices: DeviceListing) {
        self.controller = controller
        self.devices = devices
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshGlyph()
    }

    /// The glyph is the at-a-glance state: filled when routing, outline when not,
    /// and a warning triangle when something needs attention.
    func refreshGlyph() {
        let (symbol, description): (String, String) = {
            switch controller.status {
            case .active:        return ("speaker.wave.2.fill", "Spotify is routed")
            case .armed:         return ("speaker.wave.2", "waiting for Spotify")
            case .off:           return ("speaker", "not routing")
            case .misconfigured: return ("exclamationmark.triangle", "needs configuring")
            }
        }()
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: description)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status line, not clickable.
        let statusText: String = {
            if case .ok(let body) = controller.handle(.status) { return body }
            return "unknown"
        }()
        let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: routeIsOn ? "Turn Off" : "Turn On",
                                action: #selector(toggleRoute), keyEquivalent: "t")
        toggle.target = self
        menu.addItem(toggle)

        // Destination picker.
        let destinationItem = NSMenuItem(title: "Send Spotify To", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let defaultUID = devices.currentDefaultUID()
        let chosenUID = chosenDestinationUID
        if let all = try? devices.allOutputDevices() {
            for device in all {
                let isDefault = device.uid == defaultUID
                let title = isDefault ? "\(device.name) (system default)" : device.name
                let item = NSMenuItem(title: title,
                                      action: #selector(chooseDestination(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                item.state = device.uid == chosenUID ? .on : .off
                // Routing the default device to itself is refused by RouteController;
                // disable it here so the menu does not offer a dead end.
                item.isEnabled = !isDefault
                submenu.addItem(item)
            }
        }
        destinationItem.submenu = submenu
        menu.addItem(destinationItem)

        menu.addItem(.separator())
        let selftest = NSMenuItem(title: "Run Self-Test…", action: #selector(runSelfTest),
                                  keyEquivalent: "")
        selftest.target = self
        menu.addItem(selftest)

        let quit = NSMenuItem(title: "Quit SpotifyRoute", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var routeIsOn: Bool {
        switch controller.status {
        case .active, .armed: return true
        case .off, .misconfigured: return false
        }
    }

    /// Reads the persisted destination straight from the controller. An earlier draft
    /// recovered this by parsing the status display string, which was fragile and wrong.
    private var chosenDestinationUID: String? { controller.destinationUID }

    @objc private func toggleRoute() {
        report(controller.handle(.toggle))
        refreshGlyph()
    }

    @objc private func chooseDestination(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        report(controller.handle(.use(uid)))
        refreshGlyph()
    }

    @objc private func runSelfTest() {
        let reply = controller.handle(.selftest)
        let alert = NSAlert()
        switch reply {
        case .ok(let body):
            alert.messageText = "Self-test passed"
            alert.informativeText = body
        case .error(let body):
            alert.alertStyle = .warning
            alert.messageText = "Self-test failed"
            alert.informativeText = body
        }
        alert.runModal()
    }

    @objc private func quit() {
        controller.shutdown()
        NSApp.terminate(nil)
    }

    /// Only surfaces failures — success is visible in the glyph, so an alert would nag.
    private func report(_ reply: Reply) {
        guard case .error(let body) = reply else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SpotifyRoute"
        alert.informativeText = body
        alert.runModal()
    }
}
```

- [ ] **Step 2: Wire up the app**

Replace the final `print(...)` line of `Sources/SpotifyRouteApp/main.swift` with:

```swift
// ---- normal launch: menu bar app ----
let store = FileSettingsStore(url: FileSettingsStore.defaultURL)
let deviceListing = LiveDeviceListing()
let controller = RouteController(store: store,
                                 router: AudioRouter(),
                                 devices: deviceListing,
                                 processes: LiveProcessLocating(),
                                 audibility: DestinationAudibility())

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; LSUIElement also set in Info.plist

let menuBar = MenuBarController(controller: controller, devices: deviceListing)

let server = CommandServer(socketURL: CommandServer.defaultSocketURL) { command in
    let reply = controller.handle(command)
    menuBar.refreshGlyph()
    return reply
}
do {
    try server.start()
} catch {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "SpotifyRoute could not start its control socket"
    alert.informativeText = "\(error)\n\nThe menu bar still works, but the spotroute "
                          + "command and your Stream Deck button will not."
    alert.runModal()
}

let watcher = SpotifyWatcher(
    onAppeared: { controller.reapply(); menuBar.refreshGlyph() },
    onVanished: { menuBar.refreshGlyph() },
    onPlaybackStarted: { controller.reapply(); menuBar.refreshGlyph() }
)
watcher.start()

// Apply a route persisted from the last session.
controller.reapply()
menuBar.refreshGlyph()

app.run()
```

Also add `import AppKit` at the top of the file.

- [ ] **Step 3: Build the bundle and launch it**

```bash
./build.sh
open ./build/SpotifyRoute.app
```

Expected: a speaker glyph appears in the menu bar, with no Dock icon.

- [ ] **Step 4: Drive it end to end from the CLI**

```bash
./build/spotroute list
./build/spotroute use <a-non-default-device-uid-from-the-list>
./build/spotroute status
./build/spotroute selftest
./build/spotroute on
# start playing something in Spotify, listen
./build/spotroute status
./build/spotroute off
```

Expected: `list` shows devices with the default marked; `use` accepts a non-default UID and is refused for the default one; `selftest` passes with a peak near 0.25; `on` moves Spotify to the destination and leaves the system default untouched; `off` returns it. The menu bar glyph tracks each change.

- [ ] **Step 5: Verify the system default really is untouched**

While the route is on, run: `swift run SpotifyRouteApp --list-devices`
Expected: the same device is still marked `(system default)` as before routing. Confirm a call app (or any other audio source) still plays through it.

- [ ] **Step 6: Commit**

```bash
git add Sources/SpotifyRouteApp
git commit -m "Add menu bar app with destination picker

The glyph encodes state so the common case needs no clicks, and only
failures raise an alert. The system default device is offered in the
picker but disabled, since routing a device to itself is refused."
```

---

### Task 13: Login agent

**Files:**
- Create: `Resources/com.italo.spotifyroute.plist.template`
- Modify: `build.sh`

**Interfaces:**
- Consumes: the built app bundle (Task 2).
- Produces: `./build.sh --install-login-agent` and `./build.sh --uninstall-login-agent`.

- [ ] **Step 0: Single-instance guard (found in live use, not in the original plan)**

A menu-bar app the user can double-click WILL get launched twice, and a login agent makes
that likelier still — the agent starts one copy and the user opens another. Observed live:
two instances ran simultaneously after an install. `CommandServer.start()` defensively
unlinks any existing socket before binding, so the SECOND instance captures the control
channel and the FIRST is orphaned: still holding its process tap, its aggregate device and
a possibly-muted destination, unreachable by the CLI, and its eventual teardown unlinks the
socket the second instance now owns.

Add a startup check before any audio or socket setup: if another instance of this bundle
identifier is already running, activate it and exit rather than stealing the socket.
`NSRunningApplication.runningApplications(withBundleIdentifier:)` filtered against the
current process is the straightforward route. Verify by launching twice and confirming the
second exits without disturbing the first, and that the first still answers `spotroute
status` afterwards.

- [ ] **Step 1: Write the LaunchAgent template**

`Resources/com.italo.spotifyroute.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.italo.spotifyroute</string>
  <key>ProgramArguments</key>
  <array>
    <string>__APP_BINARY__</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
```

- [ ] **Step 2: Add install/uninstall to build.sh**

Insert near the top of `build.sh`, after the variable declarations:

```bash
AGENT_LABEL="com.italo.spotifyroute"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

if [ "${1:-}" = "--uninstall-login-agent" ]; then
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  echo "Login agent removed."
  exit 0
fi
```

And append at the end of `build.sh`:

```bash
if [ "${1:-}" = "--install-login-agent" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  sed "s|__APP_BINARY__|$APP/Contents/MacOS/SpotifyRouteApp|g" \
      "$ROOT/Resources/com.italo.spotifyroute.plist.template" > "$AGENT_PLIST"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  echo "Login agent installed. SpotifyRoute will start automatically at login."
  echo "Remove it with: ./build.sh --uninstall-login-agent"
fi
```

Note: the agent launches the binary inside the bundle, not the bundle, so the process keeps its bundle identity and therefore its audio-capture permission.

- [ ] **Step 2b: Add an install target to build.sh**

`build.sh` does `rm -rf` on its own output directory every run, so the bundle it produces is
scratch — a user who double-clicks it loses the app on the next build. Add
`./build.sh --install` copying the bundle to `~/Applications` (user-writable, needs no
password, appears in Spotlight and Launchpad) and the CLI to a stated location. Mention
`/Applications` as an optional `sudo` one-liner rather than doing it, since it needs an
admin password. A locally built bundle carries no quarantine attribute, so there is no
Gatekeeper prompt either way — state that in the output, because it is the main reason this
project prefers build-from-source.

- [ ] **Step 3: Install and verify**

```bash
./build.sh
./build.sh --install-login-agent
launchctl print "gui/$(id -u)/com.italo.spotifyroute" | head -20
./build/spotroute status
```

Expected: `launchctl print` shows the service; `spotroute status` answers, proving the agent-launched instance is serving the socket.

- [ ] **Step 4: Verify the route survives a restart of the agent**

```bash
./build/spotroute use <non-default-uid>
./build/spotroute on
launchctl kickstart -k "gui/$(id -u)/com.italo.spotifyroute"
sleep 3
./build/spotroute status
```

Expected: status reports `on` or `armed` — the persisted intent was re-applied by the fresh instance without user action.

- [ ] **Step 5: Commit**

```bash
git add Resources/com.italo.spotifyroute.plist.template build.sh
git commit -m "Add optional login agent

Launches the binary inside the bundle rather than the bundle itself, so
the process keeps its bundle identity and with it the audio-capture
permission grant."
```

---

### Task 14: README and LICENSE

**Files:**
- Create: `README.md`
- Create: `LICENSE`

- [ ] **Step 1: Write the LICENSE**

Standard MIT text, copyright `2026 Italo Belandria`.

- [ ] **Step 2: Write the README**

Must contain, at minimum:

- **What it does**, in one paragraph: sends Spotify to an output device you choose while your system default stays put, so calls keep working.
- **Why it exists**: Spotify has no output picker, and changing the system default moves everything.
- **Requirements**: macOS 14.2 or later, Command Line Tools (no Xcode needed). State explicitly: *"Developed and verified on macOS 26.6 only. It should work on 14.2+, but that has not been tested."*
- **Install**: `git clone`, `./build.sh`, `open ./build/SpotifyRoute.app`, optional `./build.sh --install-login-agent`, optional `sudo cp ./build/spotroute /usr/local/bin/`.
- **Usage**: the `spotroute` verbs, with a worked example.
- **Stream Deck setup**: a Multi Action Switch with two states running `spotroute on` and `spotroute off`, so the key icon reflects real state. Note the CLI must be on `PATH` or referenced by absolute path.
- **Permission section, prominent**: the first run needs audio-recording permission. **If audio is silent but everything reports success, the permission is missing or was reset** — this is the single most confusing failure mode, because macOS grants the tap and then feeds it zeros. Also note that ad-hoc signing binds the grant to the built binary, so rebuilding may require re-granting.
- **Troubleshooting**: `spotroute selftest` as the first diagnostic; "destination is the system default" refusal explained; nothing audible → check the destination's own volume and mute, which the keyboard volume keys do not control.
- **How it works**, briefly: a Core Audio process tap with `mutedWhenTapped`, feeding a private aggregate device whose main sub-device is the destination. No kernel extension, no virtual audio driver, no modification of your default device.
- **Limitations**: Spotify only; one destination at a time; unverified on non-48 kHz and Bluetooth destinations (see Task 15's findings and update this).

- [ ] **Step 3: Verify the README's own instructions from scratch**

```bash
cd /tmp && rm -rf sr-verify && git clone <local repo path> sr-verify && cd sr-verify && ./build.sh
```

Expected: a clean clone builds with no manual steps beyond what the README states. Fix the README if any step was missing.

- [ ] **Step 4: Commit**

```bash
git add README.md LICENSE
git commit -m "Add README and MIT license

The permission section is deliberately prominent: macOS grants the tap
and then delivers silence, so 'everything succeeded but I hear nothing'
is the most likely first-run experience without it."
```

---

### Task 15: Resolve the three unverified risks

The spec carries risks that were knowingly deferred. Close them and record what was actually found rather than leaving them open.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-24-spotify-route-design.md`
- Modify: `README.md` (limitations section)

- [ ] **Step 0: Is the `.app` bundle actually required for audio capture?**

The project's foundational claim, currently **unverified**. Observed once early on, then
unreproducible: the unbundled binary began passing the self-test too. Likely cause — the
development shell's ancestor application already holds audio-capture permission, and TCC
attributes the request to that responsible process, extending the grant across the whole
process tree. If so, the boundary is unobservable from that shell for any code at all.

This matters for the README, not the architecture. Keeping all Core Audio inside the
bundled app is right regardless, so no code hangs on the answer. What hangs on it is
whether the README tells people to grant a permission, and whether "reports success but
plays silence" is correctly explained as the first thing to check.

Settle it from a **clean process tree** — a Terminal.app window opened by hand, not a
shell spawned by any editor, IDE, or agent tool:

```bash
cd /path/to/SpotifyRoute
swift build
swift run SpotifyRouteApp --selftest
./build.sh
./build/SpotifyRoute.app/Contents/MacOS/SpotifyRouteApp --selftest
```

Three outcomes, each with a different consequence:

- **Unbundled fails, bundled passes** — the original finding is real. Keep the README's
  permission section prominent and restore the claim as asserted fact.
- **Both pass** — the bundle is not required for capture. Rewrite the claim as "a bundle is
  required for a *distributable* app and remains the right structure, but is not a
  precondition for the tap," and demote the README's permission language to a short
  troubleshooting note. Telling users to grant a permission they do not need is its own bug.
- **Both fail** — permission genuinely is absent in a clean tree. Document the exact grant
  procedure in the README, verified by performing it.

Either way, the README must state what was actually tested and where.

- [ ] **Step 1: Risk 2 — the playback-start edge**

```bash
./build/spotroute use <non-default-uid>
./build/spotroute on
```

Fully quit Spotify, confirm `spotroute status` reports `armed`, then launch Spotify but do **not** press play. Check status. Now press play and wait up to 3 seconds (one poll interval).

Record: does audio arrive at the destination without further action? If not, whether `SpotifyWatcher.onPlaybackStarted` fired and whether `controller.reapply()` recovered it. If reapply is insufficient, make `AudioRouter.enable` tear down and rebuild the aggregate when `statistics().callbacks == 0` after one second.

- [ ] **Step 2: Risk 3 — non-48 kHz and Bluetooth destinations**

Pick a destination whose nominal rate is not 48000 (check with `--list-devices`; set one via Audio MIDI Setup if needed), then route to it and listen for 60 seconds.

```bash
./build/spotroute use <44100-device-uid>
./build/spotroute on
```

Then repeat with a Bluetooth destination such as AirPods.

Record for each: audible artefacts, drift over 60 seconds, and perceived latency. If drift is audible, note that `kAudioSubTapDriftCompensationKey` is already enabled and the next lever is
`kAudioSubTapDriftCompensationQualityKey`.

- [ ] **Step 3: Risk 5 — behaviour at boot**

With the login agent installed and a route enabled, reboot. After logging in, without touching anything, play something in Spotify.

Record: does the route apply automatically? Does the audio-capture permission survive a reboot? Did any prompt appear?

- [ ] **Step 4: Update the spec's Risks section**

Rewrite each of Risks 2, 3 and 5 as a finding with the measured outcome, or as a documented limitation if it could not be resolved. Do not leave any of them phrased as an open question.

- [ ] **Step 5: Update the README's limitations to match**

Replace the placeholder wording from Task 14 with the actual findings, so users are told what is genuinely tested.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs README.md
git commit -m "Close out the three deferred risks with measured findings"
```

---

## Self-Review

**1. Spec coverage.** Every spec section maps to a task: problem/decisions → Tasks 8, 12; "no source device" → enforced by Task 6 (the tap never receives a device) and Task 5 (default read in exactly one place); Phase 0 findings → encoded as Global Constraints and Task 6's deliberate unbundled-failure demonstration; verified recipe → Task 6; architecture components → Tasks 4–12 one-to-one, except `Protocol.swift` (Task 3) and `SelfTest.swift` (Task 6); Stream Deck → Task 10 usage text and Task 14 README; error-handling table → Task 8's tests cover Spotify-absent, destination-missing, destination-is-default, and router failure, while permission-missing is covered by Task 6's self-test and paused-Spotify is asserted as a non-error in Task 11; testing strategy → Tasks 1, 3, 4, 8 for units and Task 6 for on-hardware; risks → Task 15; build/distribution → Tasks 2, 13, 14.

**2. Placeholder scan.** No TBD/TODO. Task 14 describes README *content requirements* rather than final prose, which is deliberate — the findings from Task 15 land there — and Task 15 Step 5 closes that loop explicitly. Every code step contains real code.

**3. Type consistency.** Checked across tasks: `RouteStatus.shortLabel` returns `"on"` for `.active`, which is what Task 8's tests assert and what Task 12's glyph switches on. `Routing.enable(destination:processObject:)` matches `AudioRouter.enable` exactly and the `FakeRouter` signature. `Audibility.prepare/restore` take `OutputDevice`, matching `DestinationAudibility` and `FakeAudibility`. `DeviceListing.allOutputDevices()` is used consistently (never `all()`, which is the `OutputDevices` static). `SelfTest.Outcome` fields `callbacks/peak/passed/detail` are used identically in Task 6's app flag and Task 8's `handleSelfTest`. `CommandServer.defaultSocketURL` is referenced by both the server and the CLI.

**Two issues found and fixed inline:**

1. `MenuBarController.chosenDestinationUID` was half-written — it tried to recover a UID by parsing a human-readable status string, which is fragile and wrong. Fixed by exposing `RouteController.destinationUID` directly and having the menu read that; the string-parsing is gone, and Task 8 gained a test covering the new accessor (15 tests, not 14).
2. The Global Constraints originally said "never read or modify the system default output device," which directly contradicted the destination-is-default refusal the spec also requires. Corrected to: never *modify* the default and never let routing depend on its identity, with exactly one permitted read — `OutputDevices.currentDefaultUID()` — used solely to refuse a self-route.

**Known deliberate ordering dependency:** Task 6 requires Task 2's bundle to verify anything, and Task 12's end-to-end check requires Tasks 8–11. Tasks must be executed in order; they are not independent.
