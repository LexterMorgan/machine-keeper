# Menu-bar app

A SwiftUI `MenuBarExtra` that shows what `mk` already knows, plus a Settings
window and an **All Rules** window. `mk` is the engine; the app is a face, and
that boundary is the design.

**The one rule:** nothing under `app/` defines a cache, a target path, or a
deletion. The app runs `mk`, decodes the versioned JSON in the root README's
[JSON boundary](../README.md#json-boundary), and renders it. A rule or path
added here breaks the model; it belongs in the engine.

It runs `mk report --json` on launch, on panel open if the last read is over
30 s old, and every 60 s; `mk clean --json` for Preview; and
`mk clean --yes --only <ids> --json` for cleanup. Timeouts: 90, 120, 180 s.
Results decode into `Report` or `CleanResult`; unknown keys are ignored and a
breaking shape change surfaces as a decode error, since the app does not branch
on `schemaVersion`.

## Data flow

```
MenuBarExtra (.window)
  MenuBarPanel                    observes the store
    ReportStore                   @MainActor @Observable
      MKService                   the only CLI gateway
        MKBinaries                resolves mk per call
        ProcessCommandRunner      Process, no shell, off-main
          mk report --json / mk clean ...
            Report, CleanResult -> Report.summary(top: 3) -> panel sections
```

`ReportStore` owns the last report, its summary, and preview/clean state. Views
read and call it. An in-flight guard drops overlapping reads, and polling pauses
during a clean or preview so a poll cannot replace the numbers being acted on;
process work and decoding run off-main, and the main actor only assigns.
Settings control the automatic interval (60 s, 5 min, or manual), a pause
switch, the menu-bar label, login-item registration, and notifications.

`mk` is resolved per call: `MK_BIN`, then `PATH`, then install directories
(Homebrew, npm global, Volta, Bun, Cargo, asdf, mise, pnpm). The child gets a
rebuilt `PATH` with the resolved directory first, so an npm shim using
`#!/usr/bin/env node` finds Node even with no inherited shell environment. If
nothing resolves, the panel says how to install `mk` or set `MK_BIN` and offers
Try Again; the menu bar shows a warning triangle.

## State model

The panel shows the last thing it actually knows.

- **First load:** "Reading disk and caches…" and a note that this takes a few
  seconds; Quit stays reachable.
- **Fresh:** numbers, "Updated just now" for five seconds, then a 24-hour clock
  time.
- **Stale after an error:** the last good report stays, labelled "Numbers below
  are from the last successful reading." The error names the cause and the next
  action: missing binary, non-zero exit with stderr, timeout, invalid JSON.
- **Missing `mk`:** the install hint and Try Again, which re-resolves at once.
- **Preview:** "Dry run — nothing deleted", the total under "Would free", and
  one row per rule with its status; toggles to "Hide preview".
- **Cleaning:** buttons disable; one line says what is running.
- **Partial or failed clean:** `mk clean` exits 0 even when rules fail, so the
  outcome comes from result rows (freed, skipped, failed, first error), and
  partial stays partial in the copy.
- **Nothing reclaimable:** "Nothing safe to clean right now" with the reason
  (caches empty, or held by running apps); no-op actions disable and an open
  confirmation closes itself.
- **Settings:** interval and pause apply immediately; the menu-bar label can be
  icon-only or icon plus free space (the latter may be hidden behind a notch);
  launch-at-login is registered through `SMAppService` only when toggled.
- **Notifications:** off by default. Enabling asks macOS for permission from
  Settings, never on launch; pressure-critical and low-disk alerts use the real
  report values and a six-hour cooldown, with separate transitions.

Every number comes from the report or clean result: no estimates, deltas, or
trend arrows. "Frees about X" is the report-time total; the clean re-measures.
The header reports when numbers were read, not how they compare.

## Safety layers

- Selection is one filter in `Report.summary`: `!optIn && !appRunning &&
  bytes > 0`. `safeRuleIDs` is every such row; the panel shows the top three and
  Clean acts on all of them.
- The app forwards only ids from the report; it never builds a path, enumerates
  a directory, or checks for a cache.
- **Opt-in cleaning is explicit and per-rule.** All Rules separates opt-in rows;
  each Clean… confirmation shows the size, risk, and reclaim note, defaults to
  Cancel, and only then sends that one id with `--include-opt-in`. Clean safe
  filters opt-in ids twice and never passes the flag.
- Deleting takes a confirmation: Cancel is the default button, Clean is
  destructive and red, so a stray Return cannot delete.
- The engine re-checks at clean time: a row that became opt-in or whose app
  started is skipped, and the app never passes `--include-opt-in`.
- Ids are one argv element (`--only a,b,c`) passed to `Process`: no shell, no
  quoting, no globbing. An empty list is rejected first, since an empty `--only`
  means no filter and would widen the set.
- Stale ids fail closed: `selectRules` throws on unknown ids before `clean`
  starts; Refresh recovers.
- A killed or timed-out clean is not transactional. The runner signals the
  child's process group (SIGTERM, then SIGKILL after a grace period); a detached
  child can escape, and half-finished work is not rolled back. The app says a
  timed-out clean may be partial; re-run to finish.

## Design

The panel answers one question in a glance: should I clean now, and what will it
free? Anything that does not serve that answer is absent.

The Memory block leads with physical RAM used-of-total (Activity Monitor's
app + wired + compressed), then a thin usage bar, swap, compressor, and the
pressure dot. If macOS omits the anonymous/file-backed counters, the RAM line
falls back to total only and the bar is not drawn; it never invents a used
figure.

- **Hierarchy:** header (name, freshness, refresh) → error → decision block
  (bytes ready, what running apps hold, opt-in bytes) → facts (disk, swap,
  pressure) → detail (largest safe rules, startup orphans) → actions → outcome →
  preview. When the decision is "nothing", the headline says so and actions
  disable.
- **Color:** one accent on the usage bar and the prominent action; Preview is
  secondary and only Clean is filled. Otherwise
  color marks state only: orange for a read error, red for the destructive step,
  green/yellow/red/gray on the pressure dot. The dot sits beside "Pressure:
  warning", repeats into the accessibility value, and is hidden from VoiceOver
  as a separate element. Color is never the only carrier.
- **Surfaces and type:** flat system backgrounds, dividers, a 6 pt radius; no
  glass, gradient, glow, shadow, decorative dot, or emoji. System font at native
  roles; sizes and percentages use monospaced digits so columns do not jitter.
  Rule ids are monospaced because they are identifiers, not terminal theatre.
- **Geometry:** 340 pt fixed width, a 54 pt label column, 12 pt padding; sizes
  right-align. A glance, not a window.
- **Accessibility and keyboard:** the menu bar item is icon-only by default for notch
  safety, with one spoken label combining name and free space. Disk and memory
  rows expose label and value; rule rows read title, size, and reclaim note as a
  hint; preview rows include status. Busy controls are disabled and keep their
  labels. Cmd-R refreshes; Return opens the clean confirmation, then cancels it,
  so a stray Return cannot delete. The header menu carries refresh, preview,
  clean, All Rules, Settings, and Quit; Settings and All Rules are also reachable
  from the panel without hunting.
- **Windows:** All Rules is a 560 pt utility window with safe/blocked/opt-in
  groups and startup orphans; Settings is a 440 pt grouped form. Both stay
  native, use the same type/palette, and never open at launch.

## Build and test

`machine-keeper-bar` holds `MkBarCore` (models, service, locator, runner,
formatting), `MkBar` (app and views), and `MkBarCoreTests`. Swift 6, macOS 15.

- `make app` builds release, assembles `dist/MachineKeeper.app` by hand
  (`Contents/MacOS` plus `Info.plist`), stamps `package.json`'s version, and
  ad-hoc signs. No Xcode project or `xcodebuild`; CommandLineTools is enough.
  Local build: not notarized, not published.
- `make app-run` launches the bundle's binary from the terminal so `MK_BIN` is
  inherited; a Finder launch gets launchd's minimal environment.
- `make app-test`, or `swift test --package-path app` (**74 tests**). Swift
  Testing, because this toolchain ships no XCTest. Core tests use the fixture
  report and a recording fake runner; no real `mk` or cache is touched.
- When the JSON changes, the fixture and the root README's contract change
  together; this app consumes the contract rather than duplicating it.

## Non-goals

- **Notch overlay.** Not now; any second face must consume the same JSON.
- **Rule editing.** Rules are engine-validated data; a UI would duplicate that.
- **Scheduling opt-in cleans.** Opt-in runs are always a human click on a
  confirmed row; nothing is included automatically.
- **Deletion, discovery, or paths in Swift.** The one rule again, and the reason
  the core stays testable.

State, gaps, and the reasoning behind these choices: [HANDOVER](../HANDOVER.md).
