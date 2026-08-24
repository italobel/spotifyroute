#!/bin/bash
# Builds SpotifyRoute with Command Line Tools only. No Xcode required.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/SpotifyRoute.app"
BUNDLE_ID="com.italo.spotifyroute"

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
# The TCC grant binds to the binary's cdhash, so rebuilding may require re-granting
# audio permission. A silent route almost always means exactly that.
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
  1. open "$APP"                       # launches the menu-bar app
  2. "$OUT/spotroute" list             # show available output devices
  3. "$OUT/spotroute" use <device-uid> # pick where Spotify should play
  4. "$OUT/spotroute" on               # route it

To install the CLI on your PATH:
  sudo cp "$OUT/spotroute" /usr/local/bin/spotroute
EOF2
