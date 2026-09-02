# About this directory

`docs/superpowers/` holds the dated design specs and implementation plans that
were written while building SpotifyRoute, kept here as a historical record of
how the app was built — not as living documentation.

The plans use checkbox syntax (`- [ ]`) to track steps during implementation.
Almost all of those boxes are still unchecked, even though the work they
describe was completed and shipped — checking them off was never part of the
workflow that produced this app. Don't read an unchecked box as "not done";
read the git history and the shipped code as the authoritative record of what
was actually built. The specs and plans are point-in-time documents, written
before or during the work they describe, and superseded as that work
progressed — most visibly, `plans/2026-08-24-spotify-route.md` describes a
menu-bar-only app with no Dock icon, which a later round of work
(`plans/2026-08-25-window-ui.md`) changed into the regular app with a window
this repo now ships.

If you only read two documents in here, make it these:

- [`specs/2026-08-24-spotify-route-design.md`](superpowers/specs/2026-08-24-spotify-route-design.md)
  — the original design: the routing engine, the process-tap approach, and the
  security model.
- [`specs/2026-08-25-window-ui-design.md`](superpowers/specs/2026-08-25-window-ui-design.md)
  — why and how the window was added.

The `plans/` files are the step-by-step implementation logs those specs
produced; useful if you want the blow-by-blow, but the specs are the better
starting point.
