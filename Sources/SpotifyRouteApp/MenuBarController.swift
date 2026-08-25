import AppKit
import Foundation
import SpotifyRouteCore

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: RouteController
    private let devices: DeviceListing
    /// Called by `toggleRoute()`/`chooseDestination(_:)` after a command completes,
    /// instead of calling `refreshGlyph()` directly. Wired to `refreshUI()` in
    /// main.swift, which refreshes this controller's glyph itself (it calls
    /// `refreshGlyph()` as its last step) and also the window — so this one call
    /// covers both surfaces. Not recursive: `refreshGlyph()` never calls back into
    /// this closure. Lets a second surface (the window) stay in sync with
    /// menu-bar-driven changes without this type knowing anything about `AppState`
    /// or the window.
    private let onStateChanged: () -> Void

    init(controller: RouteController, devices: DeviceListing,
         onStateChanged: @escaping () -> Void) {
        self.controller = controller
        self.devices = devices
        self.onStateChanged = onStateChanged
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Not onStateChanged(): at construction time (main.swift declares `menuBar`
        // before `appState`), the closure's captured `refreshUI` would touch an
        // `appState` that does not exist yet. There is also no window yet to
        // desynchronize from. Just this controller's own initial paint.
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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        if let image {
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            // A nil image here yields a zero-width, invisible status item — the exact
            // "no menu bar icon" symptom this project has already chased once as a
            // suspected environment issue. Whatever the cause (SF Symbol catalog
            // trouble, a name typo introduced later, anything), do not let it fail
            // silently: log loudly, and fall back to a short text label so the item
            // still occupies real, clickable space in the menu bar.
            FileHandle.standardError.write(("SpotifyRoute: NSImage(systemSymbolName: " +
                "\"\(symbol)\") returned nil (description: \(description)) — falling back " +
                "to a text label\n").data(using: .utf8)!)
            statusItem.button?.image = nil
            statusItem.button?.title = "SR:" + controller.status.shortLabel
        }
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
        // NSMenu.autoenablesItems defaults to true: AppKit runs a validation pass over
        // every item just before display and recomputes isEnabled for any item that has
        // a target/action, discarding the manual `item.isEnabled = false` below (the
        // item validates back to enabled because chooseDestination(_:) exists on self).
        // Without this, the system-default row would be clickable and the user would
        // hit the "refused, it's already the default" dead end this menu exists to
        // avoid presenting.
        submenu.autoenablesItems = false
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
        onStateChanged()
    }

    @objc private func chooseDestination(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        report(controller.handle(.use(uid)))
        onStateChanged()
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

    /// Teardown (route disable, audibility restore, watcher stop, socket close) all
    /// happens in `applicationWillTerminate` in main.swift, which is reached whichever
    /// way the app quits gracefully; this just asks NSApplication to go through that
    /// sequence rather than duplicating it here.
    @objc private func quit() {
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
