# SpotifyRoute — per-app audio routing for macOS

**Date:** 2026-08-24
**Status:** design approved; Phase 0 feasibility probe complete and passing

## Problem

The RODECaster Pro II Main Stereo is the system default output, and must stay that
way so every call and meeting app lands on it automatically. Spotify has no output
device picker — it follows the system default — so music cannot be sent to the
MacBook Pro Speakers without changing the default and breaking calls.

Goal: send **Spotify only** to the MacBook Pro Speakers while the system default
output remains the RODECaster, toggled from a single Stream Deck button.

## Decisions

| Question | Decision |
|---|---|
| Stream Deck behaviour | One button toggling speakers ⟷ system default |
| Scope | Spotify only, hardcoded |
| Persistence | Remember last state, re-apply at login |
| Volume control | App manages the target device's mute + volume (see Findings) |

## Phase 0 findings (measured on macOS 26.6, Apple Swift 6.2.3, CLT-only)

These are verified facts from the probe, not assumptions.

1. **A `.app` bundle with `NSAudioCaptureUsageDescription` is mandatory.** The exact
   same code compiled as a bare CLI binary creates the tap successfully, reports a
   valid stream format, delivers correctly-sized buffers — and every sample is zero.
   No error, no permission prompt. As a signed `.app` bundle with that Info.plist key,
   the identical code returns real audio. **A silent tap means a missing bundle or
   plist key, not a broken tap.** This cost the most debugging time and must not be
   rediscovered.
2. **Ad-hoc signing is sufficient.** `codesign --force --sign -` with a stable
   `--identifier`. No Developer ID, no Apple Developer Program, no full Xcode.
   Caveat: an ad-hoc TCC grant is tied to the binary's cdhash, so rebuilding the
   executable can invalidate the grant. Expect to re-grant during development.
3. **`muteBehavior = .mutedWhenTapped` genuinely removes the app from the default
   device** rather than duplicating it. Confirmed audibly: laptop speakers only,
   RODECaster silent, default device unchanged.
4. **Teardown is clean.** Destroying the IOProc, aggregate and tap returns Spotify to
   the RODECaster with no glitch and no orphaned devices, across ~15 cycles.
5. **The built-in speakers have independent volume *and* mute state.** Because the
   RODECaster is the default device, the keyboard volume keys never touch the
   built-in speakers. The first audible test failed purely because the speakers were
   muted at the device level. The app must explicitly unmute and set a sane volume
   when enabling the route.
6. **The IO cycle runs while the tapped process holds an active output stream**
   (`kAudioProcessPropertyIsRunningOutput == 1`). Callbacks continue at full rate
   even while that process is silent. A fully-paused Spotify releases its stream, and
   then no callbacks arrive — which is harmless, since there is nothing to route.
7. **`bundleIDs` and `isProcessRestoreEnabled` exist on macOS 26** and a bundle-ID-only
   tap can be *created* (`["com.spotify.client"]` reads back correctly). Note this was
   verified only as far as tap creation — it was never driven end-to-end to audio, and
   the tap's UID could not be read back while no matching process was playing.
   **Therefore the PID-targeted path is primary**, since that is what is proven audible
   end-to-end. `isProcessRestoreEnabled` is set on the PID-targeted tap as well, where
   it is documented to save tapped processes by bundle ID on exit and restore them on
   relaunch — so relaunch handling leans on it, with an app-side fallback (Risk 4).
8. Measured: 48 kHz, 2 ch, 512-frame buffers (4096 B), ≈94 callbacks/sec. Capture is
   sample-accurate — a synthesized 0.25-amplitude tone measured 0.249984.

### The verified recipe

```
tap:
  CATapDescription(stereoMixdownOfProcesses: [processObjectID])
  isPrivate = true
  muteBehavior = .mutedWhenTapped
  isProcessRestoreEnabled = true            // macOS 26+
  AudioHardwareCreateProcessTap -> tapID
  tapUID = kAudioTapPropertyUID on tapID

aggregate:
  kAudioAggregateDeviceNameKey          "SpotifyRoute"
  kAudioAggregateDeviceUIDKey           unique per instance
  kAudioAggregateDeviceMainSubDeviceKey <target device UID>   // clock master
  kAudioAggregateDeviceIsPrivateKey     true
  kAudioAggregateDeviceIsStackedKey     false
  kAudioAggregateDeviceTapAutoStartKey  true
  kAudioAggregateDeviceSubDeviceListKey [{ kAudioSubDeviceUIDKey: <target UID> }]
  kAudioAggregateDeviceTapListKey       [{ kAudioSubTapUIDKey: tapUID,
                                           kAudioSubTapDriftCompensationKey: true }]

ioproc:
  zero all output buffers first, then for i in 0..<min(inBufs, outBufs):
    memcpy(out[i], in[i], min(byteSize))
```

Gotchas found in the Swift API surface: the property is `muteBehavior` (not `isMuted`),
`isProcessRestoreEnabled` (not `processRestoreEnabled`), `isPrivate` (not `privateTap`).
`init(stereoMixdownOfProcesses:)` takes `[AudioObjectID]`, while
`init(processes:andDeviceUID:withStream:)` takes `[NSNumber]`. An unresolved type
anywhere in the expression produces a misleading "cannot infer contextual base"
error pointing at the enum rather than the real cause.

## Architecture

Two binaries, so the Stream Deck never touches Core Audio.

```
SpotifyRoute.app            LSUIElement menu-bar app, ad-hoc signed
├── AudioRouter             tap + aggregate + IOProc lifecycle
├── TargetDeviceVolume      unmute + volume for the destination device
├── RouteState              on/off, persisted; single source of truth
├── CommandServer           Unix domain socket listener
├── DeviceWatcher           device add/remove, default-device changes
└── MenuBarController       status item, manual toggle, state glyph

spotroute                   CLI: speakers | default | toggle | status
```

**Socket:** `~/Library/Application Support/SpotifyRoute/control.sock`. Line-delimited
plain text, one command per connection, replies `ok <state>` or `error <reason>`.
Chosen over a URL scheme because LaunchServices registration for an ad-hoc-signed app
in a non-standard location is unreliable, and over HTTP because a local socket needs
no port allocation and is not reachable off-machine.

### Component responsibilities

- **AudioRouter** — owns every Core Audio object. Exposes `enable()` / `disable()` /
  `isActive`. Idempotent: enabling while active is a no-op. Never throws across the
  boundary; failures are reported as a typed result so the menu bar can surface them.
- **TargetDeviceVolume** — makes the destination device actually audible on enable.
  Concrete rule, so this is not left to interpretation: unmute unconditionally; read the
  current volume and raise it to 0.5 **only if it is below 0.2**; never lower a volume
  that is already audible. On disable, restore the prior *mute* state only — deliberately
  not the prior volume, so that a volume the user adjusted while listening is not undone
  behind their back. Exists as its own unit because Finding 5 makes it a correctness
  requirement, not a nicety.
- **RouteState** — the persisted on/off flag plus an `armed` notion for when Spotify
  isn't running yet. Pure logic, no Core Audio, fully unit-testable.
- **CommandServer** — parses commands and delegates. Knows nothing about audio.
- **DeviceWatcher** — listens for `kAudioHardwarePropertyDevices` and default-device
  changes; asks AudioRouter to rebuild when the destination or default device changes.
  Also owns the `kAudioProcessPropertyIsRunningOutput` listener on the tapped process,
  which is what Risk 2's mitigation hangs off: on a 0→1 edge with the route active, if
  no callbacks have been observed it asks AudioRouter to rebuild the aggregate.

### Data flow — Stream Deck press

```
spotroute speakers
  -> socket -> CommandServer -> RouteState.enable()
  -> TargetDeviceVolume.prepare(speakers)     // unmute, floor volume
  -> AudioRouter.enable()
       resolve Spotify PID -> process object   // primary path, see Finding 7
       create tap (muted-when-tapped, process-restore enabled)
       create private aggregate (speakers master + tap)
       create + start IOProc
  -> reply "ok speakers"; MenuBarController updates glyph
```

## Stream Deck configuration

A **Multi Action Switch** with two states: state 1 runs `spotroute speakers`, state 2
runs `spotroute default`. The switch flips its own icon per press, so the button shows
where Spotify is currently going, and because both commands are explicit rather than a
blind toggle, the button cannot drift out of sync with actual state. No Stream Deck
plugin development required. (`spotroute toggle` also exists for other callers.)

## Error handling

| Condition | Behaviour |
|---|---|
| Spotify not running | Store state as *armed*; apply when it launches. Reply `ok armed`. |
| Spotify quits while routed | Tear down; stay armed; re-apply on relaunch (OS process-restore assists). |
| Spotify paused (no output stream) | No callbacks; nothing to route. Not an error. |
| Destination device absent | Refuse to enable, report which device is missing. |
| RODECaster unplugged/replugged | DeviceWatcher rebuilds the aggregate. |
| Audio capture permission missing | Detect zero-signal-while-playing; show menu-bar warning with a link to Privacy settings. |
| Aggregate/tap creation fails | Log OSStatus as FourCC, revert to off, notify. Never sit in a half-state. |

## Testing

Core Audio taps cannot be meaningfully unit-tested without hardware, so the strategy
splits by what is actually testable:

- **Real unit tests** — `RouteState` (toggle, persistence, armed transitions) and the
  `CommandServer` protocol. This is where logic bugs would actually live.
- **`spotroute selftest`** — an on-hardware integration command. Plays a synthesized
  tone from a known process, routes it, and asserts measured output RMS is non-zero.
  Turns "is audio really flowing" into a command rather than a guess, and would have
  caught the silent-CLI problem in Finding 1 immediately.
- **Manual checklist** — audible check; confirm a call app still lands on the
  RODECaster; quit/relaunch Spotify; unplug/replug the RODECaster; reboot.

## Risks

1. **TCC grant tied to cdhash.** Rebuilding may silently drop permission and reappear
   as silence. Mitigation: `selftest` asserts non-zero signal, so it fails loudly.
2. **`isRunningOutput` 0→1 edge while the aggregate is live** is not yet verified —
   whether a running aggregate picks up Spotify starting from fully-paused. Mitigation:
   watch the property and rebuild the aggregate on the edge; rebuild is already
   measured as cheap and reliable. Resolve this during implementation.
3. **Login-agent + permission interaction** at boot is unverified.
4. **Relaunch handling depends on `isProcessRestoreEnabled`,** which was set but never
   exercised through an actual Spotify quit-and-relaunch cycle. Mitigation: an
   `NSWorkspace` launch observer that re-runs `enable()` when Spotify reappears — the
   watcher the original design had, kept as a fallback rather than deleted outright.

## Out of scope

Multiple apps; arbitrary destination devices; EQ; per-app volume beyond the device
volume needed for correctness; a Stream Deck plugin proper.
