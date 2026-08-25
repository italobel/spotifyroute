import AppKit
import SwiftUI

/// Owns the app's single window. Creating the window lazily means launching with the
/// window closed is possible later without restructuring, and closing it must never
/// terminate the app — routing continues in the background.
public final class WindowController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let onToggle: () -> Void
    private let onChooseDevice: (String) -> Void
    /// Called whenever the window becomes key — opening it, clicking into it while it
    /// was already visible but not focused, or reopening via the Dock. Wired to
    /// `refreshUI()` in main.swift. Every other refresh site is a route or playback
    /// event; there is deliberately no Core Audio property listener for device-list or
    /// default-device changes (that is new mechanism, out of scope for this round), so
    /// without this the window can go stale — a newly connected device never appears,
    /// a removed one stays listed and clickable — until something else happens to
    /// trigger a refresh. This closes the gap for the common case: the user looks at
    /// or clicks into the window.
    private let onBecomeKey: () -> Void
    private var window: NSWindow?

    public init(state: AppState,
                onToggle: @escaping () -> Void,
                onChooseDevice: @escaping (String) -> Void,
                onBecomeKey: @escaping () -> Void) {
        self.state = state
        self.onToggle = onToggle
        self.onChooseDevice = onChooseDevice
        self.onBecomeKey = onBecomeKey
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
        // .resizable: a long device name is otherwise free to widen the window with no
        // way to shrink it back, on the only reachable surface if that happens.
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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

    /// Fires on `showWindow()`'s `makeKeyAndOrderFront` (first open and every
    /// reopen) and on the user clicking into an already-visible-but-unfocused
    /// window — the two moments a stale window is most likely to be looked at.
    public func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey()
    }
}
