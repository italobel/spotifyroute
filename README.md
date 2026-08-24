# SpotifyRoute

SpotifyRoute sends Spotify's audio — and only Spotify's — to an output device you
choose, while your Mac's system default output stays exactly where it was.

## What it does

Spotify's desktop client has no output picker. It just follows whatever your Mac
considers the default output device. So if you want Spotify playing somewhere
specific, the usual fix is to change your system default — which also drags every
call, meeting, and notification sound along with it, since they all follow the same
setting. SpotifyRoute breaks that link: pick a destination for Spotify once, and
everything else keeps using the system default as normal.

The author's own setup is the motivating case: a RODECaster Pro II is the system
default, so every call lands on it automatically, while Spotify plays from the
MacBook's built-in speakers instead.

## How it works

SpotifyRoute uses a Core Audio **process tap** scoped to Spotify's process
(`stereoMixdownOfProcesses`, resolved against `com.spotify.client`), with
`muteBehavior = .mutedWhenTapped`. That setting is what makes this a *move* rather
than a copy: the instant the tap engages, Spotify goes silent on its normal output,
and its audio appears only at the destination.

The tap feeds a private aggregate device whose main sub-device is the destination
you chose, so the tap and the destination share one clock domain and need no
resampling. There is no kernel extension and no virtual audio driver involved, and
your system default output device is never modified — not its identity, not its
volume, nothing.

There is also no notion of a "source device" anywhere in the code. The tap is bound
to Spotify's process, not to any particular output, so if you change your system
default — new headphones, a dock, AirPods, whatever — the route is unaffected,
because it never knew what the default was in the first place.

One more thing routing does deliberately: turning a route on unmutes the
destination device, and raises its volume to 0.5 if it reads below 0.2 or can't be
read at all. This exists because a device that isn't your system default keeps its
own independent mute and volume state — the kind your keyboard's volume keys never
reach — and an early version of this app failed an audible test outright because
the destination was muted at the device level while reporting 1.000 volume.
Turning the route off restores the destination's prior *mute* state, but
deliberately not its prior volume: if you turned the volume up while listening,
putting the old value back would silently undo that change. If you've deliberately
muted a monitor or interface, know that routing Spotify to it will unmute it.

## Security and privacy

Granting an app permission to record system audio is worth being cautious about, so
here is exactly what this code does and does not do:

- The tap only ever captures Spotify. It's built from
  `CATapDescription(stereoMixdownOfProcesses:)` against the single resolved
  `com.spotify.client` process object — there is no global/system-wide tap variant
  anywhere in the source.
- Both the tap and the aggregate device it feeds are created with `isPrivate = true`,
  so they exist only for this process; nothing else on the system can see or attach
  to them.
- Captured Spotify audio itself is never written to disk, buffered, or
  accumulated. It's copied directly from the input buffer to the output buffer
  inside the IOProc callback and nowhere else — the only thing that survives past
  a single callback is one peak-amplitude float, used for the self-test's
  pass/fail measurement.
- There are no network APIs anywhere in this codebase. The only sockets it opens
  are `AF_UNIX` — a local control socket at
  `~/Library/Application Support/SpotifyRoute/control.sock`, used only by the
  `spotroute` CLI on the same machine.
- The only file this app *persists* is a small settings JSON holding a device UID
  and a boolean (your chosen destination and whether routing is on). The one other
  thing it ever writes to disk is `spotroute selftest`'s own test tone: a WAV file
  it synthesizes itself in the system temp directory, plays once, and deletes
  immediately afterward. That file is a tone the app generated, never your
  captured audio, and it does not outlive the self-test that created it.
- The only subprocess this app ever spawns is `/usr/bin/afplay`, and only when you
  run `spotroute selftest` — to play that self-generated test tone.
- There's no AppleScript, no Accessibility API, no screen-capture or window-listing
  API used anywhere. `Info.plist` declares exactly one permission
  (`NSAudioCaptureUsageDescription`), and the app ships with no entitlements at all.

One honest limitation: the macOS permission itself is not scoped to Spotify, or to
any single app you're capturing from — a process holding audio-capture permission
could, in principle, tap any process's audio. The Spotify-only scoping described
above lives in this project's code, not in the permission macOS grants. That's the
actual reason this project ships as source you build yourself rather than a
prebuilt binary: you don't have to take the scoping on faith, you can read it.

If you ran an unbundled development build directly from a terminal at some point,
macOS may have attributed the audio-capture grant to your terminal application
instead of to SpotifyRoute. The installed app carries its own independent grant, so
that terminal permission (System Settings → Privacy & Security, under Audio
Recording) isn't needed once SpotifyRoute is installed properly, and you can revoke
it.

## Requirements

| | |
|---|---|
| macOS | 14.2 or later (that's the release Core Audio process taps first shipped in) |
| Toolchain | Command Line Tools only — no Xcode install needed |
| Spotify | The desktop client (`com.spotify.client`) |

**Developed and verified only on macOS 26.6, on Apple Silicon.** It should work on
14.2 and later, but that has not been tested — if you try it on an older release,
the permission and self-test sections below are the places to check first.

Command Line Tools alone can't run XCTest or swift-testing — both require a full
Xcode install — so this project ships its own small test harness instead of
depending on either.

## Install

```bash
git clone https://github.com/italobel/spotifyroute.git
cd spotifyroute
./build.sh
```

This compiles the app and CLI, assembles `build/SpotifyRoute.app`, ad-hoc signs it,
and drops `build/spotroute` next to it. No Developer ID or Apple Developer account
is needed — ad-hoc signing is enough for a process tap. Launch it with:

```bash
open ./build/SpotifyRoute.app
```

It's a menu-bar-only app (no Dock icon, no window) — look for its icon in the menu
bar to open the destination picker and toggle.

To install it somewhere permanent:

```bash
./build.sh --install
```

This copies the app to `~/Applications/SpotifyRoute.app` and the CLI to
`~/.local/bin/spotroute`. `~/Applications` needs no admin password and still shows
up in Spotlight and Launchpad like any other app — launch it from there, or with
`open ~/Applications/SpotifyRoute.app`. `~/.local/bin` is **not** on macOS's
default `PATH`; check with `echo $PATH` and add it in your shell's profile if it's
missing, or just call the CLI by its full path (`~/.local/bin/spotroute`).
`--install` refuses to run while an existing installed copy is running — quit it
from its menu bar icon first, then re-run the command.

If you'd rather install system-wide (this needs an admin password):

```bash
sudo cp -R build/SpotifyRoute.app /Applications/SpotifyRoute.app
sudo cp build/spotroute /usr/local/bin/spotroute
```

A locally built app carries no quarantine attribute, so macOS shows no Gatekeeper
warning either way — that's the main reason this project is distributed as source
you build rather than as a signed download.

Optional: have it start automatically at login:

```bash
./build.sh --install-login-agent
```

Remove it later with:

```bash
./build.sh --uninstall-login-agent
```

## Permission on first launch

The first time SpotifyRoute tries to capture Spotify's audio, macOS will prompt you
to grant audio-recording permission (visible afterward in System Settings →
Privacy & Security, under Audio Recording). Grant it — this permission is what lets
the process tap receive real samples instead of silence.

Two things worth knowing about this, since they're the most common source of
confusion:

- **If `spotroute on` reports success but you hear nothing, the permission is the
  first thing to check.** macOS is capable of creating the tap, running it, and
  handing back correctly-sized, well-formed audio buffers that are simply all
  zero — no error, no warning. Run `spotroute selftest`: it plays a tone the app
  generates itself and measures whether real, non-zero audio actually made it
  through the route, rather than just checking that no error was returned.
- **Rebuilding the app can make macOS ask for permission again.** The grant is tied
  to the built app's code signature. Ad-hoc signing means that rebuilding from
  unchanged source reproduces the same binary and the same signature, so nothing
  changes and there's no new prompt — but any change to the compiled code produces
  a new signature, which macOS treats as a new app requiring a fresh grant. In
  practice: build once and install it, and you get one prompt. Keep rebuilding it
  as you develop, and you'll get a prompt after each code change. If you've
  installed the login agent, this matters more: the next login-agent-launched
  instance after a code-changing rebuild starts with nobody there to click
  "Allow," so it can come up and route silently with no permission. `spotroute
  selftest` is how you'd notice.

## Usage

```
$ spotroute --help
spotroute — control SpotifyRoute

  spotroute on              route Spotify to the chosen destination
  spotroute off             send Spotify back to the system default
  spotroute toggle          flip between the two
  spotroute status          show current state
  spotroute list            list available output devices
  spotroute use "<uid>"     choose the destination device (quote UID if it contains spaces)
  spotroute selftest        verify audio really flows (uses the app's permission)
```

Device UIDs are not friendly strings — real ones contain spaces, colons, and
sometimes non-ASCII characters, for example:

```
AppleUSBAudioEngine:RØDE:RODECaster Pro II:GV1234567:4,5
```

**Always quote the UID** when you pass it to `use`. A worked example — the `list`
output below is real, taken from the author's own machine:

```
$ spotroute list
DELL S2721QS
    10AC1111-0000-0000-0000-000000000000
DELL S2722QC
    10AC2222-0000-0000-0000-000000000000
RODECaster Pro II Chat
    AppleUSBAudioEngine:RØDE:RODECaster Pro II:GV1234567:1,2
RODECaster Pro II Main Stereo  [system default]
    AppleUSBAudioEngine:RØDE:RODECaster Pro II:GV1234567:4,5
MacBook Pro Speakers  [chosen destination]
    BuiltInSpeakerDevice
Camo Microphone
    CamoAudioDevice_UID
Splashtop Remote Sound
    SplashtopRemoteSoundDevice_UID

$ spotroute use "AppleUSBAudioEngine:RØDE:RODECaster Pro II:GV1234567:1,2"
destination set to RODECaster Pro II Chat

$ spotroute on
on
```

Note that `RODECaster Pro II Main Stereo` is the system default here, so `use`
targets `RODECaster Pro II Chat` instead — a different sub-device on the same
interface. Trying to `use` the UID marked `[system default]` would be refused (see
Troubleshooting).

If SpotifyRoute isn't installed on your `PATH`, run it by its full path instead,
e.g. `~/.local/bin/spotroute list` or `./build/spotroute list`.

Exit codes are meant to be scripted against: `0` on success, `1` on error (or if
the app isn't running at all), `2` on a usage error (bad or missing arguments).

## Stream Deck setup

Configure a **Multi Action Switch** with two states: one running `spotroute on`,
the other `spotroute off`. The key flips its own icon per press, so it always shows
where Spotify is actually going — and because both states run an explicit command
rather than a blind toggle, the key can't drift out of sync with reality the way a
naive toggle button could.

The Stream Deck needs to find `spotroute`. `./build.sh --install` puts it at
`~/.local/bin/spotroute`, which is not on macOS's default `PATH` — check whether
yours includes it (`echo $PATH`) and add it if not, or simply point the Stream
Deck action at the CLI's absolute path (`~/.local/bin/spotroute`, or
`/usr/local/bin/spotroute` if you used the `sudo cp` one-liner instead).

## Troubleshooting

**`spotroute on` succeeds but I hear nothing.** Check the permission first (see
above) and run `spotroute selftest`. It's the fastest way to tell "the permission
is missing" apart from "something else is wrong."

**Nothing is audible on a monitor or an audio interface, even though `selftest`
passes.** Some output devices don't expose a software volume control at all —
their volume is entirely hardware-controlled (a physical knob or dial), and macOS
has no way to raise it. On the author's own machine, five of seven output devices
fall into this category: two Dell monitors, both RODECaster Pro II sub-devices, and
one virtual device (a Splashtop remote-desktop audio output). SpotifyRoute can't
make an inaudible hardware-controlled device audible, and it won't tell you when
that's the problem — check the device's own physical volume control. This is a
hardware limitation, not a bug in the app.

**`"<device>" is already your system default; routing it to itself only adds
latency`.** This is refused on purpose — sending Spotify to the device it's already
going to would only add processing overhead with no benefit. Pick a different
destination, or change your system default if you actually want the RODECaster (or
whatever it is) to be default.

**I was prompted for permission again after rebuilding.** Expected — see
"Permission on first launch" above.

## Limitations

- Spotify only. No other app's audio is touched.
- One destination at a time.
- Verified only on macOS 26.6, on Apple Silicon. 14.2 and later should work but is
  untested.
- No notarized, prebuilt release — build from source with `./build.sh`.
- The system default output device is never modified, under any circumstance.

## License

MIT — see [LICENSE](LICENSE).
