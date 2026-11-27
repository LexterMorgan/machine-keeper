# Menu-bar app

A SwiftUI `MenuBarExtra` that shows what `mk` already knows, plus Settings,
**All Rules**, and a separate **Explore** window. `mk` is the cleanup engine;
the app is a face, and that boundary is the design.

**The one rule:** nothing under `app/` defines a cleanup cache, rule, target
path, or cleanup deletion. The app runs `mk`, decodes the versioned JSON in the
root README's [JSON boundary](../README.md#json-boundary), and renders it.
Explore is deliberately different: it searches files and moves individually
selected regular files to the native Trash. It never writes rules, never feeds
Clean Safe or scheduled cleanup, and shares the CLI's never-touch policy rather
than defining a second cleanup registry.

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

Explore window
  ExploreModel                  @MainActor @Observable, scan generations
    ExploreService              off-main, cancellable, bounded scan
    ExploreTrashService         native Trash + per-file revalidation
      ProtectionPolicy          policy.json shared with the CLI guard
```

`ReportStore` owns the last report, its summary, and preview/clean state. Views
read and call it. An in-flight guard drops overlapping reads, and polling pauses
during a clean or preview so a poll cannot replace the numbers being acted on;
process work and decoding run off-main, and the main actor only assigns.
Settings control the automatic interval (60 s, 5 min, or manual), a pause
switch, the menu-bar label, login-item registration, and notifications.

`mk` is resolved per call: `MK_BIN`, then the CLI inside the app bundle, then an
external `mk` on `PATH` or in common install directories. The bundled CLI is run
through Node discovered from `MK_NODE`, `PATH`, and the same install
directories; Node 20+ is required. If the bundle exists but Node is missing,
an installed external `mk` is still used; if neither works, the panel explains
whether to install Node or set `MK_BIN` and offers Try Again. The menu bar shows
a warning triangle.

The child gets a rebuilt `PATH` with the resolved runtime directory first, so
the bundled script can still find `du`, `pgrep`, and friends with no inherited
shell environment.

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
  started is skipped. Clean safe never passes `--include-opt-in`; only the
  explicit per-rule All Rules path does.
- Ids are one argv element (`--only a,b,c`) passed to `Process`: no shell, no
  quoting, no globbing. An empty list is rejected first, since an empty `--only`
  means no filter and would widen the set.
- Stale ids fail closed: `selectRules` throws on unknown ids before `clean`
  starts; Refresh recovers.
- A killed or timed-out clean is not transactional. The runner signals the
  child's process group (SIGTERM, grace, SIGKILL), does not reap the leader
  until after the group signal so a surviving helper cannot escape and the
  group ID cannot be reused, and only then reports the timeout. A child that
  deliberately detaches into a new process group can still escape, and
  half-finished work is not rolled back. The app says a timed-out clean may be
  partial; re-run to finish.

## Explore

Explore answers a different question: "what is in this folder?" It is not a
rule builder and has no path into the cleanup registry.

- The root must be a folder inside the current user's home; the canonical home
  and root are checked. Containment is exact canonical filesystem ancestry, so
  `Work` and `work` stay distinct on a case-sensitive volume; only protected
  names are matched case-insensitively. A directly selected root or any of its
  ancestors that is hidden or a package is rejected before enumeration.
  Results show the full canonical path, size, and modification date.
- Filters combine with AND: filename substring, extension (case-insensitive,
  leading dot optional), minimum size, and modified-after date.
- Scans run off-main, are capped at 500 matches, and are cancelled by changing
  folder/filter state. A generation counter discards stale results. Skipped
  and unreadable locations are listed; `isTruncated` is proven by finding one
  extra match beyond the cap.
- Traversal returns regular files only. It skips symlinks (including symlinked
  folders), hidden entries, `.app` bundles, and packages; unreadable folders
  are reported rather than silently omitted.
- The never-touch list from `policy.json` is shared with the CLI guard.
  Explore additionally treats `~/Library` as protected. Protected results stay
  visible with a reason, but selection cannot lead to a Trash action. Root and
  file protection are both checked in the code that performs the move.
- Selection starts empty and clears on folder/filter changes. The confirmation
  sheet lists the exact paths, count, and total size. The only operation is
  `FileManager.trashItem`; there is no permanent-delete fallback. Outcomes are
  per file, and only `.trashed` rows leave the result/selection set. The copy
  says "moved to Trash", never "freed".
- Immediately before each move, canonical home/root/parent are re-resolved and
  every directory up to home is rechecked for Finder's hidden flag, dot names,
  package status, and readable metadata. The file is `lstat`ed as a regular,
  non-symlink file with matching device/inode, size, and mtime. Changed, moved,
  hidden, package, protected, or unverifiable files are skipped and reported.
- Remaining race: the final validation and `trashItem` are not atomic. A file
  swapped in that window cannot be detected by `FileManager`; this is
  documented here and in the Trash service.

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
  (`Contents/MacOS`, `Info.plist`, `Contents/Resources/policy.json`, and
  `Contents/Resources/cli`), stamps `package.json`'s version, and ad-hoc signs.
  The copied CLI includes `bin/`, `src/`, `rules.default.json`, `policy.json`,
  `package.json`, and `LICENSE`, so a Finder launch does not need `npm link`.
  No Xcode project or `xcodebuild`; CommandLineTools is enough. Local build:
  not notarized, not published.
- `make app-run` launches the bundle's binary from the terminal; `MK_NODE` and
  `MK_BIN` are inherited for development overrides. A Finder launch uses the
  bundled CLI and launchd's minimal environment.
- `make app-test`, or `swift test --package-path app` (**120 tests**). Swift
  Testing, because this toolchain ships no XCTest. Core tests use the fixture
  report and a recording fake runner; no real `mk` or cache is touched.
- When the JSON changes, the fixture and the root README's contract change
  together; this app consumes the contract rather than duplicating it.

## Non-goals

- **Notch overlay.** Not now; any second face must consume the same JSON.
- **Rule editing.** Rules are engine-validated data; a UI would duplicate that.
- **Scheduling opt-in cleans.** Opt-in runs are always a human click on a
  confirmed row; nothing is included automatically.
- **Cleanup deletion, cleanup discovery, or cleanup paths in Swift.** The
  engine still owns rules and cleanup. Explore's Trash surface is separate and
  never writes a registry entry.

State, gaps, and the reasoning behind these choices: [HANDOVER](../HANDOVER.md).
