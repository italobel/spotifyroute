import AppKit
import SwiftUI

/// Owns the app's single window. Creating the window lazily means launching with the
/// window closed is possible later without restructuring, and closing it must never
/// terminate the app — routing continues in the background.
public final class WindowController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let onToggle: () -> Void
    private let onChooseDevice: (String) -> Void
    private var window: NSWindow?

    public var hasWindow: Bool { window != nil }

    public init(state: AppState,
                onToggle: @escaping () -> Void,
                onChooseDevice: @escaping (String) -> Void) {
        self.state = state
        self.onToggle = onToggle
        self.onChooseDevice = onChooseDevice
        super.init()
    }

    public func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = MainWindowView(state: state,
                                  onToggle: onToggle,
                                  onChooseDevice: onChooseDevice)
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "SpotifyRoute"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false   // we reuse this instance on reopen
        w.center()
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing hides the window; it does not quit. The app is a routing service that
    /// happens to have a window, not a document app.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
