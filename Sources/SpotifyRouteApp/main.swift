import AppKit
import Foundation
import SpotifyRouteCore
import SpotifyRouteUI

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

if args.first == "--selftest" {
    // Second argument is an optional destination UID; defaults to built-in speakers.
    // A UID that WAS supplied but does not resolve must fail rather than silently
    // fall back (I-5 review): built-in speakers is the one destination class where
    // the C-1 tap-offset bug was invisible, so a typo would silently test the safe
    // case and report PASS instead of surfacing the mistake.
    do {
        let devices = try OutputDevices.all()
        let requested = args.count > 1 ? args[1] : nil
        let destination: OutputDevice
        if let uid = requested {
            guard let match = devices.first(where: { $0.uid == uid }) else {
                throw RouteError.deviceNotFound(uid)
            }
            destination = match
        } else {
            guard let fallback = devices.first(where: { $0.uid == "BuiltInSpeakerDevice" })
                    ?? devices.first
            else {
                print("no output devices available")
                exit(1)
            }
            destination = fallback
        }
        print("self-testing against \(destination.name) (\(destination.uid))")
        let outcome = try SelfTest.run(destination: destination,
                                       seconds: SelfTest.defaultMeasurementSeconds)
        print("callbacks=\(outcome.callbacks) peak=\(outcome.peak)")
        print(outcome.passed ? "PASS — \(outcome.detail)" : "FAIL — \(outcome.detail)")
        exit(outcome.passed ? 0 : 1)
    } catch {
        print("FAIL — \(error)")
        exit(1)
    }
}

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

// ---- normal launch: menu bar app ----

// Single-instance guard (Task 13, Step 0). A menu-bar app the user can double-click
// WILL get launched twice, and a login agent makes that likelier still — the agent
// starts one copy at login and the user opens a second from Spotlight or Launchpad
// without realizing one is already running. CommandServer.start() defensively
// unlinks any existing socket before binding, so a second launch would silently
// steal the control channel out from under the first: the first instance would be
// orphaned still holding its process tap, its private aggregate device, and a
// destination whose mute state it may have changed, with no menu or CLI able to
// reach it, and its eventual teardown would unlink the socket the second instance
// now owns. Checking here — before touching the socket or any Core Audio object —
// means the loser exits cleanly instead of racing the winner for shared OS state.
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.italo.spotifyroute"
let currentPID = ProcessInfo.processInfo.processIdentifier
let runningPeers = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleIdentifier)
    .filter { $0.processIdentifier != currentPID }
if let alreadyRunning = runningPeers.first {
    alreadyRunning.activate()
    exit(0)
}

/// Stops the control socket, disables the route, and stops the Spotify watcher on
/// graceful termination. All three live here (not in `MenuBarController.quit()`)
/// because this hook — `applicationWillTerminate` — is the one place reached by every
/// graceful-quit path: the menu's Quit item (`NSApp.terminate(nil)`), and the standard
/// `quit` Apple Event (System Events, logout). The Dock tile's own Quit item sends the
/// same Apple Event, so it reaches this hook too — no separate Dock-quit path to worry
/// about. SIGTERM (plain `kill`/`pkill`)
/// and SIGKILL both bypass this entirely, same as any Cocoa app that does not install a
/// signal handler; `CommandServer.start()` already unlinks a stale socket left behind
/// by either case, and a stale route re-applies harmlessly on next launch since
/// `shutdown()` deliberately leaves `routeEnabled` untouched.
///
/// `watcher.stop()` runs first so a poll tick landing mid-teardown cannot call
/// `reapply()` and re-enable the very route `shutdown()` is about to tear down —
/// `reapply()` only guards on `routeEnabled && !router.isActive`, which a tick between
/// `shutdown()` and process exit would satisfy.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let onTerminate: () -> Void
    let onLaunch: () -> Void
    let onReopen: () -> Void

    init(onTerminate: @escaping () -> Void,
         onLaunch: @escaping () -> Void,
         onReopen: @escaping () -> Void) {
        self.onTerminate = onTerminate
        self.onLaunch = onLaunch
        self.onReopen = onReopen
    }

    func applicationWillTerminate(_ notification: Notification) { onTerminate() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch()
    }

    /// Clicking the Dock icon when no window is visible. This is the primary way back
    /// to the window, so it must always produce one.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        onReopen()
        return true
    }

    /// Closing the window must not quit — routing continues in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let store = FileSettingsStore(url: FileSettingsStore.defaultURL)
let deviceListing = LiveDeviceListing()
let controller = RouteController(store: store,
                                 router: AudioRouter(),
                                 devices: deviceListing,
                                 processes: LiveProcessLocating(),
                                 audibility: DestinationAudibility())

let app = NSApplication.shared
// .regular, not .accessory: the window must be reopenable from the Dock. A menu-bar-only
// app is unusable when the menu bar is full, which is the problem this window solves.
app.setActivationPolicy(.regular)

let menuBar = MenuBarController(controller: controller, devices: deviceListing)

let appState = AppState()

/// Reads current reality into a snapshot. Called at exactly the points that already
/// refresh the menu bar glyph, so the window and the glyph never disagree.
func currentSnapshot() -> AppState.Snapshot {
    let spotify: SpotifyPresence
    if let process = try? SpotifyProcess.processObject() {
        spotify = SpotifyProcess.isProducingOutput(process) ? .playing : .paused
    } else {
        spotify = .notRunning
    }
    return AppState.Snapshot(status: controller.status,
                             destinationUID: controller.destinationUID,
                             devices: (try? deviceListing.allOutputDevices()) ?? [],
                             systemDefaultUID: deviceListing.currentDefaultUID(),
                             spotify: spotify)
}

func refreshUI() {
    appState.apply(currentSnapshot())
    menuBar.refreshGlyph()
}

let windowController = WindowController(
    state: appState,
    onToggle: {
        appState.beginWork()
        // Deferred so one render pass completes and "Working…" is actually visible
        // before the Core Audio call blocks the main thread. See the spec's
        // "pending-permission wedge" section: nothing can render during the block.
        DispatchQueue.main.async {
            _ = controller.handle(.toggle)
            appState.endWork()
            refreshUI()
        }
    },
    onChooseDevice: { uid in
        appState.beginWork()
        DispatchQueue.main.async {
            _ = controller.handle(.use(uid))
            appState.endWork()
            refreshUI()
        }
    }
)

let server = CommandServer(socketURL: CommandServer.defaultSocketURL) { command in
    let reply = controller.handle(command)
    refreshUI()
    return reply
}

let watcher = SpotifyWatcher(
    onAppeared: { controller.reapply(); refreshUI() },
    onVanished: { refreshUI() },
    onPlaybackStarted: { controller.reapply(); refreshUI() }
)

let appDelegate = AppDelegate(
    onTerminate: {
        watcher.stop()
        controller.shutdown()
        server.stop()
    },
    onLaunch: { windowController.showWindow(); refreshUI() },
    onReopen: { windowController.showWindow(); refreshUI() }
)
app.delegate = appDelegate

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

watcher.start()

// Apply a route persisted from the last session.
controller.reapply()
refreshUI()

app.run()
