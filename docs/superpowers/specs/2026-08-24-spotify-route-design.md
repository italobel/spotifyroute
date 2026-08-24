# SpotifyRoute — send Spotify to any output device, without changing your default

**Date:** 2026-08-24
**Status:** design approved; Phase 0 feasibility probe complete and passing
**Target:** public GitHub repo, build-from-source

## Problem

Spotify's desktop client has no output picker — it follows the system default output
device. So sending music to a different device means changing the system default, which
then also moves every call, meeting and notification. That's the wrong trade: the
default should stay wherever calls need it.

**SpotifyRoute sends Spotify — and only Spotify — to a device you choose, while the
system default output is left completely untouched.**

The author's case: the system default is a RODECaster Pro II Main Stereo so that all
call audio lands on it automatically, while Spotify plays from the MacBook Pro Speakers.
But nothing in the design is specific to that hardware (see "No source device" below).

## Decisions

| Question | Decision |
|---|---|
| What we leave alone | The system default output, whatever it happens to be. Never read as config, never modified. |
| Destination | User-selectable from any available output device; persisted. |
| App routed | Spotify only (`com.spotify.client`). |
| Toggle | One Stream Deck button, on ⟷ off. |
| Persistence | Remember route state and chosen destination; re-apply at login. |
| Minimum macOS | 14.2 (where process taps landed). Developed and verified only on 26.6. |
| Distribution | Build from source via a one-line script; ad-hoc signed locally. |

### No source device

A process tap is **not bound to an output device**. `stereoMixdownOfProcesses` captures
what the process produces, wherever it was headed. Phase 0 confirmed this: the tap was
never told about the RODECaster and captured Spotify off it regardless.

This matters more than it sounds. It means the code contains **no notion of a source
device at all** — no "RODECaster", no reading of the default device, nothing to keep in
sync. Swap the default for headphones, a dock, or AirPods and the app is unaffected,
because it never knew. The only device ever named is the destination.

## Phase 0 findings (measured on macOS 26.6, Apple Swift 6.2.3, Command Line Tools only)

Verified facts from the probe, not assumptions.

1. **A `.app` bundle with `NSAudioCaptureUsageDescription` is mandatory, and the user must grant audio-capture permission.** *(STATUS: CONFIRMED by the human on 2026-08-24. Running the unbundled binary from a plain Terminal prompted for permission, which they granted. The earlier development-environment result — where an unbundled binary appeared to work — is explained by TCC attributing the request to an already-authorised ancestor process, masking the boundary. Both the cdhash-binding theory and the no-grant-needed theory were wrong; the requirement is real.)* The identical
   code as a bare CLI binary creates the tap successfully, reports a valid stream
   format, delivers correctly-sized buffers — and every sample is zero. No error, no
   permission prompt. As a signed `.app` bundle with that Info.plist key, the same code
   returns real audio. **A silent tap means a missing bundle or plist key, not a broken
   tap.** This cost the most debugging time of anything in Phase 0 and must not be
   rediscovered.
2. **Ad-hoc signing is sufficient.** `codesign --force --sign -` with a stable
   `--identifier`. No Developer ID, no Apple Developer Program, no full Xcode. Caveat:
   an ad-hoc TCC grant binds to the binary's cdhash, so rebuilding the executable can
   invalidate the grant — expect to re-grant during development.
3. **`muteBehavior = .mutedWhenTapped` genuinely removes the app from its normal output**
   rather than duplicating it. Confirmed audibly: destination only, default device
   silent for Spotify, default device unchanged.
4. **Teardown is clean.** Destroying IOProc, aggregate and tap returns Spotify to the
   default with no glitch and no orphaned devices, across ~15 cycles.
5. **Output devices carry independent volume *and* mute state.** Because the default
   device is something else, the keyboard volume keys never touch the destination. The
   first audible test failed purely because the destination was muted at the device
   level while reporting volume 1.000. The app must handle this explicitly.
6. **The IO cycle runs while the tapped process holds an active output stream**
   (`kAudioProcessPropertyIsRunningOutput == 1`). Callbacks continue at full rate even
   while that process is silent. A fully-paused Spotify releases its stream and no
   callbacks arrive — harmless, as there is nothing to route.
7. **`bundleIDs` and `isProcessRestoreEnabled` exist on macOS 26** and a bundle-ID-only
   tap can be *created* (`["com.spotify.client"]` reads back correctly). Verified only
   as far as creation — never driven end-to-end to audio, and the tap UID could not be
   read while no matching process played. **The PID-targeted path is primary**, being
   what is proven audible. With a 14.2 minimum these two properties are unavailable on
   most supported versions anyway, so they are opportunistic only.
8. Measured: 48 kHz, 2 ch, 512-frame buffers (4096 B), ≈94 callbacks/sec. Capture is
   sample-accurate — a synthesized 0.25-amplitude tone measured 0.249984.

### The verified recipe

```
tap:
  CATapDescription(stereoMixdownOfProcesses: [processObjectID])
  isPrivate    = true
  muteBehavior = .mutedWhenTapped
  isProcessRestoreEnabled = true            // macOS 26+ only, behind #available
  AudioHardwareCreateProcessTap -> tapID
  tapUID = kAudioTapPropertyUID on tapID

aggregate:
  kAudioAggregateDeviceNameKey          "SpotifyRoute"
  kAudioAggregateDeviceUIDKey           unique per instance
  kAudioAggregateDeviceMainSubDeviceKey <destination UID>      // clock master
  kAudioAggregateDeviceIsPrivateKey     true
  kAudioAggregateDeviceIsStackedKey     false
  kAudioAggregateDeviceTapAutoStartKey  true
  kAudioAggregateDeviceSubDeviceListKey [{ kAudioSubDeviceUIDKey: <destination UID> }]
  kAudioAggregateDeviceTapListKey       [{ kAudioSubTapUIDKey: tapUID,
                                           kAudioSubTapDriftCompensationKey: true }]

ioproc:
  zero all output buffers first, then for i in 0..<min(inBufs, outBufs):
    memcpy(out[i], in[i], min(byteSize))
```

Swift API gotchas found the hard way: the property is `muteBehavior` (not `isMuted`),
`isProcessRestoreEnabled` (not `processRestoreEnabled`), `isPrivate` (not `privateTap`).
`init(stereoMixdownOfProcesses:)` takes `[AudioObjectID]` while
`init(processes:andDeviceUID:withStream:)` takes `[NSNumber]`. An unresolved type
anywhere in an expression yields a misleading "cannot infer contextual base" error
pointing at the enum rather than the real cause.

## Architecture

Two binaries, so the Stream Deck never touches Core Audio.

```
SpotifyRoute.app            LSUIElement menu-bar app, ad-hoc signed
├── AudioRouter             tap + aggregate + IOProc lifecycle
├── OutputDevices           enumerate output devices; resolve + watch UIDs
├── DestinationAudibility   unmute + volume floor for the chosen destination
├── Settings                route state + destination UID, persisted
├── SpotifyWatcher          launch/quit observation; isRunningOutput edges
├── CommandServer           Unix domain socket listener
└── MenuBarController        status item, toggle, destination picker, state glyph

spotroute                   CLI: on | off | toggle | status | list | use <uid|name>
```

**Socket:** `~/Library/Application Support/SpotifyRoute/control.sock`. Line-delimited
text, one command per connection, replying `ok <state>` or `error <reason>`. Chosen over
a URL scheme because LaunchServices registration for an ad-hoc-signed app in a
non-standard location is unreliable, and over HTTP because a local socket needs no port
and is not reachable off-machine.

### Component responsibilities

- **AudioRouter** — owns every Core Audio object. `enable(destinationUID:)` / `disable()`
  / `isActive`. Idempotent: enabling while active with the same destination is a no-op;
  with a different destination it rebuilds. Never throws across its boundary; failures
  come back as a typed result the menu bar can surface.
- **OutputDevices** — lists devices having output channels, with name + UID; resolves a
  persisted UID back to a live device; reports when the chosen destination disappears.
  UID is the persisted identity, never the name, since names collide and change.
- **DestinationAudibility** — makes the chosen destination actually audible. Concrete
  rule so this is not left to interpretation: unmute unconditionally; read the current
  volume and raise it to 0.5 **only if below 0.2**; never lower an already-audible
  volume. On disable, restore the prior *mute* state only — deliberately not the prior
  volume, so a volume the user adjusted while listening isn't undone behind their back.
  Its own unit because Finding 5 makes it a correctness requirement, not a nicety.
- **Settings** — persisted route state and destination UID, plus an `armed` notion for
  when Spotify isn't running yet. Pure logic, no Core Audio, fully unit-testable.
- **SpotifyWatcher** — `NSWorkspace` launch/terminate observers to re-apply an armed
  route when Spotify reappears (required, not optional, since `isProcessRestoreEnabled`
  is macOS 26+ and the floor is 14.2). Also owns the
  `kAudioProcessPropertyIsRunningOutput` listener backing Risk 2's mitigation: on a 0→1
  edge with the route active and no callbacks observed, ask AudioRouter to rebuild.
- **CommandServer** — parses commands, delegates. Knows nothing about audio.
- **MenuBarController** — glyph reflecting current state, manual toggle, and a
  destination submenu listing available output devices with the current one checked.

### Data flow — Stream Deck press

```
spotroute on
  -> socket -> CommandServer -> Settings.enable()
  -> resolve persisted destination UID -> live device (error if gone)
  -> DestinationAudibility.prepare(device)          // unmute, volume floor
  -> AudioRouter.enable(destinationUID:)
       resolve Spotify PID -> process object        // primary path, Finding 7
       create tap (muted-when-tapped)
       create private aggregate (destination master + tap)
       create + start IOProc
  -> reply "ok on"; MenuBarController updates glyph
```

## Stream Deck configuration

A **Multi Action Switch** with two states: state 1 runs `spotroute on`, state 2 runs
`spotroute off`. The switch flips its own icon per press, so the button shows current
state, and because both commands are explicit rather than a blind toggle the button
cannot drift out of sync with reality. No Stream Deck plugin development needed.
`spotroute toggle` also exists for other callers.

## Error handling

| Condition | Behaviour |
|---|---|
| Spotify not running | Store state as *armed*; apply on launch. Reply `ok armed`. |
| Spotify quits while routed | Tear down; stay armed; re-apply on relaunch. |
| Spotify paused (no output stream) | No callbacks; nothing to route. Not an error. |
| Destination device unplugged | Disable the route, keep the preference, notify. Spotify falls back to the default on its own. |
| Persisted destination missing at launch | Stay off, show it in the menu, don't silently pick a substitute. |
| Destination == current default device | Refuse with a clear message; routing a device to itself only adds latency. |
| Destination sample rate ≠ tap rate | Drift compensation is enabled; if it still fails, report rather than emit garbage (Risk 3). |
| Audio capture permission missing | Detect zero signal while `isRunningOutput == 1`; menu-bar warning linking to Privacy settings. |
| Aggregate/tap creation fails | Log OSStatus as FourCC, revert to off, notify. Never sit in a half-state. |

## Testing

Core Audio taps can't be meaningfully unit-tested without hardware, so the strategy
splits by what is genuinely testable:

- **Real unit tests** — `Settings` (toggle, persistence, armed transitions, destination
  round-trip), the `CommandServer` protocol, and `DestinationAudibility`'s volume-floor
  rule as a pure function. This is where logic bugs actually live.
- **`spotroute selftest`** — an on-hardware integration command. Plays a synthesized
  tone from a known process, routes it to the chosen destination, asserts measured
  output RMS is non-zero. Turns "is audio really flowing" into a command rather than a
  guess, and would have caught Finding 1 immediately.
- **Manual checklist** — audible check; confirm a call app still lands on the default;
  quit/relaunch Spotify; unplug/replug the destination; change the system default while
  routed; reboot.

## Risks

1. **RESOLVED: audio capture requires a granted permission.** Confirmed by the human from a
   clean Terminal — the prompt appeared and they granted it. Two earlier theories were both
   wrong (that the grant binds to the cdhash; that no grant is needed), each inferred inside
   a shell whose ancestor already held the permission. The README must therefore document the
   grant as a required first-run step. Mitigated in code regardless: `selftest` asserts
   measured non-zero signal, so a missing grant fails loudly rather than silently.
2. **PARTIALLY VERIFIED: the `isRunningOutput` 0→1 edge is confirmed edge-triggered by
   code, but a genuine playback-start pickup was never observed end-to-end.** Reading
   `SpotifyWatcher.poll()` confirms the check is `if producing && !wasProducingOutput` —
   a false→true transition, not a level check, so it cannot re-fire on every tick while
   Spotify keeps playing. A 35-second, 17-tick soak during Task 12 (persisted route
   active, Spotify paused, temporary logging added and fully reverted before commit)
   measured this directly: `reapply()`/`router.enable()` fired exactly once, at startup,
   and never again across those 17 ticks, every one of which observed `producing=false`.
   That establishes the no-false-positive half — an already-working route does not
   spuriously rebuild while Spotify sits paused. It does **not** establish the positive
   half: whether pressing play after a genuine pause actually reaches
   `onPlaybackStarted()` and recovers audio within one poll interval. Exercising that
   requires either fully quitting Spotify or driving playback via AppleScript (which
   triggers its own Automation permission prompt); both were out of bounds for a machine
   in active use, so **this half remains genuinely untested** — record it as such rather
   than as verified. The mitigation described for an insufficient `reapply()` — tearing
   down and rebuilding when `statistics().callbacks == 0` a second after the edge — has
   not been implemented, because there is no measurement yet showing `reapply()` needs it.
3. **VERIFIED with measurements: a 44.1 kHz destination does not corrupt or silence the
   route, but shows a small, intermittent amplitude artefact a matching-rate destination
   does not; Bluetooth remains untested.** Tested `Splashtop Remote Sound`
   (`SplashtopRemoteSoundDevice_UID`, nominal 44100 Hz — a virtual device, so this could
   be exercised directly with no audible side effect) against `MacBook Pro Speakers`
   (`BuiltInSpeakerDevice`, 48000 Hz) as a same-rate control, using `spotroute selftest`'s
   fixed 0.25-amplitude, 3-second measurement.

   - Splashtop: `destinationInputBufferCount=1`, computed `tapInputOffset=1`,
     `aggregateInputBufferCount=2` on the built aggregate — Splashtop is an input-bearing
     virtual device, so this is genuinely the offset-1 branch of the C-1 tap-offset fix, the
     same branch a Bluetooth headset would exercise. Across 8 selftest runs: 6 measured
     peak ≈0.2500 (within 0.1% of the source amplitude), 2 measured peak ≈0.267–0.269
     (≈7–8% above it).
   - Control (BuiltInSpeakerDevice, matching rate): `destinationInputBufferCount=0`,
     `tapInputOffset=0`, `aggregateInputBufferCount=1`. Across 8 selftest runs, every peak
     fell in a tight 0.2500–0.2510 band — no outliers.

   Every run on both destinations passed (peak always far above the 0.001 failure
   threshold — no zero signal, no error). The intermittent overshoot appears only on the
   rate-mismatched destination, which is the expected signature of
   `kAudioSubTapDriftCompensationKey` performing asynchronous sample-rate conversion:
   interpolation ripple depends on the phase alignment between the tap's native 48 kHz
   clock and the destination's 44.1 kHz clock at the instant of measurement, which is
   exactly why it shows up in some runs and not others rather than every run. This is a
   real, measured finding, not a failure: drift compensation keeps the route working and
   correctly shaped, but does not make a resampled destination bit-identical to a
   matching-rate one. If this proves audible in practice, `kAudioSubTapDriftCompensationQualityKey`
   is the next lever, unexercised here.

   **Bluetooth is untested and could not be tested in this session**: no Bluetooth audio
   device was connected on this machine (confirmed via `system_profiler
   SPBluetoothDataType` — only a Bluetooth mouse was paired), and pairing one purely to
   test was out of scope. A Bluetooth headset is, like Splashtop, an input-bearing
   device, so it would exercise the same offset-1 tap-position path already measured
   above — but it would additionally introduce real over-the-air latency and a genuinely
   asynchronous clock that a virtual loopback device cannot reproduce, so Bluetooth's
   latency and clock-drift behavior remain a real, open gap, not merely a formality.
4. **Only verified on macOS 26.6** while claiming 14.2. The README must say exactly
   that rather than implying tested support.
5. **UNTESTED: a genuine reboot was not performed and must not be inferred as passing
   from anything measured so far.** No reboot was run — rebooting this machine was
   explicitly out of bounds for this task. The closest available evidence is Task 13's
   `launchctl kickstart -k` test: after quitting the running app and force-restarting it
   through launchd (not `open`, not the CLI), `spotroute status` answered immediately and
   `spotroute selftest` measured real audio (peak ≈0.26) through the launchd-started
   process, confirming the audio-capture permission survives a launchd-initiated relaunch
   within the same login session. That is the closest proxy available short of rebooting,
   but it is not the same test: a real reboot also exercises TCC/launchd state after a
   cold boot, the relative order in which SpotifyRoute's login agent and Spotify's own
   login item get launched, and whether a route marked `routeEnabled` reapplies correctly
   whichever of those launches first. None of that has been observed — the login agent
   was not installed for this task and was left untouched. Whoever runs the real test
   should specifically check: (1) whether a permission prompt reappears after reboot — it
   should not, since the grant is tied to the app bundle's stable ad-hoc signature, not the
   login session; (2) whether `reapply()` still fires correctly if Spotify's own login
   item happens to launch after SpotifyRoute's; (3) `spotroute selftest` immediately after
   login, to catch a state where the route looks active but is silently carrying zero
   signal.

## Build and distribution

- `./build.sh` — compiles with `swiftc`/SwiftPM, assembles the `.app` bundle, writes the
  Info.plist including `NSAudioCaptureUsageDescription`, ad-hoc signs, and installs the
  `spotroute` CLI. No Xcode required, only Command Line Tools.
- A locally built binary is not quarantined, so there is no Gatekeeper prompt to work
  around — the main reason to prefer build-from-source over a prebuilt release.
- README must state plainly: what it does, the macOS floor and what was actually tested,
  that a first run needs the audio-capture permission, and that a silent route almost
  always means the permission was denied or reset (Finding 1).
- LICENSE: MIT.

## Out of scope

Multiple simultaneously routed apps; routing apps other than Spotify; EQ; per-app volume
beyond the device volume needed for correctness; a Stream Deck plugin proper; notarized
prebuilt releases.
