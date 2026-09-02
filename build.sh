#!/bin/bash
# Builds SpotifyRoute with Command Line Tools only. No Xcode required.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/SpotifyRoute.app"
BUNDLE_ID="com.italo.spotifyroute"

AGENT_LABEL="com.italo.spotifyroute"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
# ~/Applications, not /Applications: user-writable, needs no admin password, and
# still shows up in Spotlight and Launchpad. This is also the location the login
# agent points at, so the installed copy survives `./build.sh`'s rm -rf of the
# scratch build/ directory — see install_to_applications below.
INSTALLED_APP="$HOME/Applications/SpotifyRoute.app"
INSTALLED_CLI="$HOME/.local/bin/spotroute"

usage() {
  cat <<EOF0
Usage: $0 [--install | --install-login-agent | --uninstall-login-agent]

  (no flag)                build only, output to build/
  --install                 also install to ~/Applications and ~/.local/bin
  --install-login-agent     also install and start automatically at login
  --uninstall-login-agent   remove the login agent (no build)
EOF0
}

case "${1:-}" in
  ""|--install|--install-login-agent|--uninstall-login-agent)
    ;;
  *)
    echo "Unknown flag: ${1}" >&2
    usage >&2
    exit 1
    ;;
esac

if [ "${1:-}" = "--uninstall-login-agent" ]; then
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  echo "Login agent removed."
  exit 0
fi

echo "==> Building ($CONFIG)"
# Build only the two shipping products, not the whole package: SpotifyRouteTests uses
# @testable import, which SwiftPM only supports when the imported module is compiled
# with -enable-testing. That happens automatically for debug builds but not for
# release, so `swift build -c release` with no --product filter fails partway through
# on the test executable even though neither shipping product depends on it.
swift build -c "$CONFIG" --package-path "$ROOT" --product SpotifyRouteApp
swift build -c "$CONFIG" --package-path "$ROOT" --product spotroute
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist.template" "$APP/Contents/Info.plist"
cp "$BIN/SpotifyRouteApp" "$APP/Contents/MacOS/SpotifyRouteApp"

echo "==> Ad-hoc signing"
# Ad-hoc signing is sufficient for Core Audio process taps; no Developer ID needed.
# Confirmed (not speculation): the TCC audio-capture grant binds to the binary's
# cdhash. Rebuilding from unchanged source reproduces the identical binary and
# cdhash, so no new prompt; any change to compiled source produces a new cdhash,
# which macOS treats as a brand new app requiring a fresh grant. That matters for
# the login agent: after a rebuild that changed code, the next login-agent-started
# launch happens with no human present to answer that prompt, so it may come up
# without audio permission and route silently. `spotroute selftest` is the
# diagnostic — it fails loudly instead of passing on silence.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

echo "==> Installing CLI"
mkdir -p "$OUT"
cp "$BIN/spotroute" "$OUT/spotroute"

cat <<EOF2

Build complete.

  App: $APP
  CLI: $OUT/spotroute

Next:
  1. open "$APP"                       # launches the app; its window opens automatically
  2. "$OUT/spotroute" list             # show available output devices
  3. "$OUT/spotroute" use <device-uid> # pick where Spotify should play
  4. "$OUT/spotroute" on               # route it

To install the CLI on your PATH:
  sudo cp "$OUT/spotroute" /usr/local/bin/spotroute

To install permanently (survives the next build's rm -rf of build/SpotifyRoute.app):
  ./build.sh --install
EOF2

# Copies the just-built bundle and CLI to a location that survives the next build's
# rm -rf of $APP. `build/SpotifyRoute.app` above is scratch output: every invocation
# of this script deletes and recreates it, so anything that pointed at it directly
# (a Dock/Launchpad entry, a login agent) would end up pointing at whatever this
# script produces next, built with different content and, after re-signing, a
# different cdhash. Copying to a stable path outside build/ avoids that.
install_to_applications() {
  # Refuse to replace a bundle that is currently running, rather than lean on the
  # fact that unlinking a directory out from under an already-open executable
  # happens to be harmless on this codebase today (one Bundle.main access, at
  # launch, before any lazy bundle-resource read). That safety is implicit, not
  # enforced, and a bad habit to bake into an installer a stranger might run
  # against their own live install.
  if pgrep -f "$INSTALLED_APP/Contents/MacOS/SpotifyRouteApp" >/dev/null 2>&1; then
    echo "==> $INSTALLED_APP is currently running — not overwriting it."
    echo "    Quit SpotifyRoute first (menu bar icon, or:"
    echo "      osascript -e 'tell application id \"$BUNDLE_ID\" to quit'"
    echo "    ), then re-run this command."
    return 1
  fi

  echo "==> Installing app to $INSTALLED_APP"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED_APP"
  cp -R "$APP" "$INSTALLED_APP"

  echo "==> Installing CLI to $INSTALLED_CLI"
  mkdir -p "$HOME/.local/bin"
  cp "$OUT/spotroute" "$INSTALLED_CLI"
}

if [ "${1:-}" = "--install" ] || [ "${1:-}" = "--install-login-agent" ]; then
  if ! install_to_applications; then
    exit 1
  fi
  cat <<EOF3

Installed:
  App: $INSTALLED_APP
  CLI: $INSTALLED_CLI

~/Applications needs no admin password and still appears in Spotlight and Launchpad.
For a system-wide install instead (requires an admin password):
  sudo cp -R "$APP" /Applications/SpotifyRoute.app

This bundle was built locally, not downloaded, so it carries no quarantine
attribute — macOS will not show a Gatekeeper prompt for it either way. That is
the main reason this project ships as source rather than a signed download.

Make sure $HOME/.local/bin is on your PATH. If you would rather not add it,
install the CLI system-wide instead (requires an admin password):
  sudo cp "$OUT/spotroute" /usr/local/bin/spotroute
EOF3
fi

if [ "${1:-}" = "--install-login-agent" ]; then
  echo "==> Installing login agent"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed "s|__APP_BINARY__|$INSTALLED_APP/Contents/MacOS/SpotifyRouteApp|g" \
      "$ROOT/Resources/com.italo.spotifyroute.plist.template" > "$AGENT_PLIST"
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  echo "Login agent installed. SpotifyRoute will start automatically at login."
  echo "It launches the binary inside $INSTALLED_APP, not the bundle itself, so the"
  echo "process keeps its bundle identity and with it the audio-capture permission grant."
  echo "Remove it with: ./build.sh --uninstall-login-agent"
fi
