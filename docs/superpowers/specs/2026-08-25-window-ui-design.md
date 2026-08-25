# SpotifyRoute window UI — design

**Status:** approved in conversation; implementation not started
**Builds on:** `2026-08-24-spotify-route-design.md` (the routing engine, unchanged by this work)

## Problem

SpotifyRoute currently has no window. Its only graphical surface is a menu bar item,
and the author's menu bar is crowded enough on a laptop screen that the item was
unreachable — they could not change the destination at all until told the CLI
equivalent. A menu-bar-only app you cannot click is, for that user, simply broken.

Non-technical users also have no discoverable surface: nothing opens, nothing appears
in the Dock, and the CLI is not an answer for them.

## Goal

A window showing whether Spotify is playing, where its audio is going, and letting the
user change the destination and toggle routing — reachable without depending on menu
bar real estate.

## Decisions

| Question | Decision |
|---|---|
| Dock presence | Regular app with a Dock icon. Click it to reopen the window. |
| Menu bar item | Kept. Fast toggle when reachable; the window is the fallback. |
| Window content | Playing state, current destination, device picker, on/off. Nothing else. |
| Closing the window | Does not quit — routing continues in the background. |
| Quitting | Explicit only: ⌘Q or the menu bar's Quit. |
| UI framework | SwiftUI. Verified to compile with Command Line Tools alone; no Xcode. |

## Architecture

New code is split across **two** targets, not the single app target this section
originally planned. See "Why a separate `SpotifyRouteUI` target" below for what changed
and why. `SpotifyRouteCore` gains one additive callback (see "The one change outside the
app target"); nothing else about it changes.

```
Sources/SpotifyRouteUI/          new library target, depends on SpotifyRouteCore
├── AppState.swift          ObservableObject — the window's single source of truth
├── RouteDisplay.swift      pure display model (SpotifyPresence, Activity, DeviceRow, ...)
├── MainWindowView.swift    SwiftUI view
└── WindowController.swift  owns the NSWindow; show / reopen behaviour

Sources/SpotifyRouteApp/
├── MenuBarController.swift unchanged
└── main.swift              constructs AppState/WindowController and updates them at
                             the existing refresh points
```

### Why a separate `SpotifyRouteUI` target

This section originally planned for all new code to live in the existing app target, with
`Package.swift` unchanged. That was not workable: `SpotifyRouteApp` is an
`.executableTarget`, and Swift Package Manager cannot `import` an executable target — only
library targets are importable. The "Testing" section below requires real unit tests
against `AppState` and the display-derivation logic, from `SpotifyRouteTests`; code that
cannot be imported cannot be tested, so it could not have lived in `SpotifyRouteApp`.

The fix is a new library target, `SpotifyRouteUI`, holding everything that needs unit
tests or that the SwiftUI view needs: `AppState`, the pure display model, the view itself,
and `WindowController`. `SpotifyRouteApp` shrinks to `main.swift` and
`MenuBarController.swift` — wiring, not logic. `SpotifyRouteApp` and `SpotifyRouteTests`
both depend on `SpotifyRouteUI`.

This does change `Package.swift` (one new target, two new dependency edges), but it
preserves this section's actual intent: `SpotifyRouteCore` — the library `spotroute`
links — still carries no SwiftUI or Combine, and `spotroute` still depends only on
`SpotifyRouteCore`, exactly as before. The boundary that matters was never "the app
target" specifically; it was keeping SwiftUI/Combine out of the library the CLI links.
That boundary holds — it just needed a second, testable target on the app side rather
than one, to hold it.

### How state reaches the window

`refreshGlyph()` is already called from five places — app startup, the watcher's
appeared / vanished / playback-started callbacks, and the socket command handler.
Those are exactly the moments the window also needs to update. Each gains a matching
`appState.refresh(from: controller)` call. No new notification mechanism is invented.

`AppState` holds:

- `routeStatus: RouteStatus` — from `controller.status`
- `destinationName: String?` — resolved from `controller.destinationUID`
- `devices: [OutputDevice]` plus the current system default UID
- `spotifyPlaying: Bool`
- `activity: Activity` — `.idle` or `.working` (see "The pending-permission wedge")

### The one change outside the app target

A live "Spotify is playing" indicator needs the *current* level.
`SpotifyWatcher` currently reports only the 0→1 *edge*, because that is all an
armed-route re-apply needs. It gains a callback reporting the polled level — fired
whenever that level differs from the previous poll tick, in either direction, not on
every tick regardless of change. (An earlier draft of this callback fired
unconditionally on every tick and wired it straight to a full UI refresh; that would
have meant enumerating every output device and resolving Spotify's process object
every 2 seconds indefinitely, which is wasteful and was corrected before
implementation.) This is additive; the existing edge callback and its semantics are
untouched.

## Window content

One column, in this order:

1. **Spotify** — playing / paused / not running.
2. **Route** — off, or "on → <device name>", or armed, or misconfigured. Uses the
   existing `RouteStatus`.
3. **Send Spotify to** — the output devices. The current system default is listed but
   **disabled**, matching the menu's rule, because routing a device to itself is
   refused by `RouteController`. The chosen destination is checked.
4. **On/off control.**

**Window actions call `RouteController` directly**, in-process, exactly as the menu bar
already does. They do not go through the control socket — that exists for out-of-process
callers like the CLI and the Stream Deck. One consequence worth stating: the socket's
three-second command bound does not apply to window actions, so a window action that
blocks has no timeout at all.

Failures surface inline in the window rather than as modal alerts. The menu bar keeps
using its existing alerts; this design does not change that surface, so the two behave
differently on failure by design rather than by oversight.

## The pending-permission wedge

While a macOS permission prompt is pending, `AudioHardwareCreateProcessTap` blocks on
the main thread. Every socket command then times out with "app busy", and with a
window present the window itself freezes. This was observed live.

**Self-review caught that my first plan for this does not work.** I intended to show
"Working…" and then escalate to "Waiting for permission" after a two-second timer. That
escalation is unreachable: the window calls the controller on the main thread, so while
`AudioHardwareCreateProcessTap` blocks, no timer fires, no render happens, and no state
change can reach the screen. Any design that promises a UI update *during* the block is
fiction.

What is actually achievable without touching the threading: set `.working` and let one
render pass complete *before* the blocking call begins, by deferring the call with
`DispatchQueue.main.async`. The user then sees "Working…" rather than an unexplained
frozen window. When the call returns, the reply — including a failure — is displayed
normally.

**Decision: accept the freeze, label it, and do not restructure the threading.** Moving
Core Audio enable/disable to a serial queue is the correct long-term architecture, but it
would rework `RouteController`'s main-thread confinement and `AudioRouter`'s call
discipline — both reviewed heavily — to improve a case that now occurs only around a
first permission grant on a newly built binary.

Recorded as a known limitation, in the README as well as here: while a permission dialog
is pending the window shows "Working…" and does not respond until the dialog is answered.
If this proves annoying in practice, the fix is the serial queue, and it is a separate
piece of work with its own review.

## Error handling

| Condition | Behaviour |
|---|---|
| Destination device disappeared | Window shows the route as off with the device named as unavailable. |
| No destination chosen yet | Device picker prompts for a choice; the toggle is disabled. |
| Permission missing | The reply's failure text is shown inline, with a pointer to Privacy & Security. Note this appears *after* any pending dialog is answered, not during. |
| Command fails | Inline message in the window; no modal. |
| Device list unreadable | Explicit "could not read output devices" row rather than an empty list. |

## Testing

`AppState`'s derivation from a controller snapshot is pure logic and gets real unit
tests through the existing harness: each `RouteStatus` maps to the right display state,
the default device is marked disabled, and a missing destination is distinguishable from
a destination that is present but off.

The SwiftUI view and window lifecycle cannot be meaningfully unit-tested without a UI
harness, so they get a manual checklist: window opens on first launch; closing it leaves
routing running; the Dock icon reopens it; it updates when the Stream Deck or CLI
changes the route; it updates when Spotify starts and stops playing; the system default
row is visibly disabled; quitting still restores the destination's prior mute state.

## Out of scope

Settings of any kind, including start-at-login and hiding the menu bar item. Volume
control. Diagnostics such as the self-test. Routing anything other than Spotify. These
are deliberate omissions, not oversights — the window exists so the destination can be
changed without the menu bar, and nothing more.
