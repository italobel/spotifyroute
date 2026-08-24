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
