# Handover

State of the project for the next person or session. Keep this current; it is
the cheapest way to transfer context that would otherwise live in a chat log.

Last updated: 2026-11-26, menu-bar app with settings, All Rules, notifications, and RAM metrics.

## What this is

`machine-keeper` audits and reclaims disk space on macOS developer machines.
It is an MIT-licensed CLI (`mk`) plus a thin SwiftUI menu-bar app, written for
8 GB and 16 GB laptops where accumulated caches are the difference between
usable and swapping.

The CLI needs Node 20+, with no runtime dependencies, no build step, no
network, no sudo. The app is Swift 6 + SwiftPM for macOS 15; CommandLineTools
is enough, no Xcode.

## Status

- Engine complete and working: `report`, `clean`, `startup`, `rules`,
  `schedule`. 17 rules; 48 Node tests passing.
- `mk report --json` and `mk clean --json` carry `schemaVersion: 1`;
  `test/report-json.test.mjs` pins the consumer contract. The pin is now the
  literal `1`, not just `JSON_SCHEMA_VERSION` echoing itself, and clean stdout
  is exercised end-to-end: a real `main(["clean", "--json"])` run is parsed as
  one JSON document, with the seeded cache asserted still in place.
- Audit fixes are in: clean passes `--json` so the app's decode path actually
  runs, the Swift byte formatter matches `src/bytes.mjs` rounding, and the
  engine fails closed when `pgrep` cannot answer (unknown is treated as running).
  `risk: "user-files"` now requires `optIn: true` at validation time.
- Menu-bar app in `app/`: `LSUIElement`, menu bar only, no Dock icon. It runs
  `mk report --json` every 60 s by default (Settings: 5 min, manual, or pause);
  preview is `mk clean --json`; Clean safe is
  `mk clean --yes --only <safe ids> --json`. It contains no rules, paths, or
  deletion code.
- App surface: Settings (refresh, menu-bar label, launch at login via
  `SMAppService`, notifications), an All Rules window (safe/blocked/opt-in
  groups, startup orphans with Reveal), explicit per-rule opt-in cleaning behind
  a confirmation, and a header quick-actions menu. The panel reports physical
  RAM used-of-total alongside swap and pressure. Notifications are off by
  default and request permission only from Settings.
- 74 Swift tests passing (`swift test --package-path app`), written with Swift
  Testing because this machine's CommandLineTools has no XCTest.
- CI covers the CLI matrix (macOS + Ubuntu, Node 20 and 22) and, separately,
  builds and tests the app on macOS.
- `make app` hand-assembles `dist/MachineKeeper.app` (`Contents/MacOS` plus
  `Info.plist`) and ad-hoc signs it; `make app-run` and `make app-test` wrap it.
- `MK_BIN` overrides `mk` discovery; otherwise the app checks `PATH` and common
  Homebrew, npm, and node-version-manager directories. A missing `mk` shows the
  error and setup hint instead of crashing.
- Not notarized, not published to npm. Pushed to GitHub at
  `github.com/LexterMorgan/machine-keeper`.

Verify before changing anything:

```bash
node --test test/*.test.mjs                  # must stay 48/48 or grow
node bin/mk.mjs report             # real, read-only output
node bin/mk.mjs clean              # dry run, nothing deleted
swift test --package-path app      # must stay 74/74 or grow
make app                           # hand-built bundle; open dist/MachineKeeper.app
```

## Layout

| Path | Responsibility |
|---|---|
| `bin/mk.mjs` | entry point; forwards argv, maps errors to exit codes |
| `src/cli.mjs` | arg parsing, commands, human output, `--json` |
| `src/schema.mjs` | `JSON_SCHEMA_VERSION`; bumped only for a breaking shape change |
| `src/rules.mjs` | registry validation, `--only` selection, opt-in filtering |
| `src/guard.mjs` | path guard: home-relative only, protected locations refused |
| `src/report.mjs` | disk + memory + per-rule footprint; pure of side effects |
| `src/clean.mjs` | dry-run by default; app-quit guard; per-rule isolation |
| `src/startup.mjs` | launch agents/daemons, orphan detection, login items |
| `src/schedule.mjs` | monthly launchd report (never cleans) |
| `rules.default.json` | the allowlist; rules are data, not code |
| `test/` | 48 Node tests; temp homes only, no real-home writes |
| `test/report-json.test.mjs` | contract test: pins the literal `schemaVersion` and the report/clean `--json` shapes |
| `app/` | SwiftPM package: `MkBar` menu-bar executable, `MkBarCore` logic, Swift tests |
| `app/README.md` | app architecture, state model, safety, and design narration |
| `app/Sources/MkBar/` | panel, Settings, All Rules, settings/notifications, menu-bar scenes |
| `app/Info.plist` | bundle metadata: `LSUIElement`, macOS 15 minimum, version |
| `Makefile` | `test`, `app` (hand-built bundle), `app-run`, `app-test`, `app-clean` |

## Invariants (do not weaken)

- Deletion targets are **allowlisted**, never discovered by scanning.
- **Dry run is the default**; `--yes` is required to delete anything.
- A cache is skipped while its owning app is running.
- Anything with user value is `optIn` and marked `risk: "user-files"`.
- No `sudo`, no system paths, no recursion into Downloads, no network.
- The guard refuses `Documents`, `Desktop`, `Pictures`, `Projects`, `.ssh`,
  `Library/Containers`, `Library/Mobile Documents` even if a rule names them.
- **The app is a face, not an engine.** Swift code contains no rule
  definitions, target paths, or deletion logic. It reads `mk report --json`,
  previews `mk clean --json`, and deletes only through
  `mk clean --yes --only <ids> --json` with ids the report returned. Choosing
  safe rows is allowed; inventing ids or paths is not.
- **Opt-in deletion is explicit.** `--include-opt-in` is sent only for a single
  opt-in rule the user selected in All Rules, after a confirmation whose default
  is Cancel. Clean safe filters opt-in ids and never sends the flag.

## Decisions already made

1. **The CLI is the engine; any GUI is a face.** Implemented in `app/`: it
   shells out to `mk report --json` and `mk clean --json` and never
   reimplements rules, paths, or deletion.
2. **The JSON boundary is versioned and additive.** `schemaVersion` is `1`
   (`src/schema.mjs`); bump it only for a removal or retype. Consumers ignore
   unknown keys. `test/report-json.test.mjs` and the README "JSON boundary"
   section move together with any shape change.
3. **Menu-bar app first, notch panel later.** The `MenuBarExtra` panel (disk,
   swap, pressure dot, top three reclaimables, orphan count, Refresh, Preview
   clean, Clean safe) is the useful 90%. A boringNotch-style overlay is a
   separate, riskier project.
4. **No Xcode on this machine.** Only CommandLineTools, Swift 6.0.3, macOS SDK
   15.2, arm64, macOS 15 target. SwiftPM (`swift build`) plus a hand-written
   `.app` bundle (`make app`, `Info.plist` with `LSUIElement`); ad-hoc signing
   is fine, notarization is out of scope. Tests use Swift Testing because
   CommandLineTools ships no XCTest.
5. **Resolve `mk` per call, not at launch.** A GUI does not inherit a shell
   `PATH`, so `MK_BIN` wins, then `PATH`, then known install directories.
   Resolving inside each command means installing `mk` later works without a
   relaunch.
6. **macOS-first.** Linux is welcome later; the rule model and metrics would
   need separate path/command implementations, not a rewrite.

## Known gaps

- **Not notarized.** `make app` ad-hoc signs; a downloadable build needs a
  Developer ID and notarization, or users build it locally.
- **No npm publish.** `github.com/LexterMorgan/machine-keeper` is the home;
  neither the CLI nor the app is on npm yet (`npm link` is the install path).
- **Launch at login is untested on this ad-hoc build.** The Settings toggle uses
  `SMAppService.mainApp`; macOS may require a signed bundle and Login Items
  approval, and the UI surfaces the error if registration fails.
- **Notifications are permission-gated.** They are off by default, request
  permission only from Settings, and were not delivered in automated checks; a
  bare `swift run` no-ops because `UNUserNotificationCenter` needs an app bundle.
- **Notch panel deferred.** The menu bar plus Settings/All Rules windows are the
  surfaces for now.
- **A cancelled or timed-out clean is not transactional.** The runner signals
  the child's whole process group on timeout (SIGTERM, then SIGKILL), but it
  does not observe Swift task cancellation, and a killed clean can stop
  half-done with no rollback. The app says so when a clean times out; re-run to
  finish. A descendant that deliberately detaches into a new process group can
  still escape.
- **Stale safe ids fail closed.** The app sends the ids from its last report; if
  the registry changed since, the CLI rejects the request before deleting
  anything. That is a visible error and one Refresh away, not a partial clean.
- Startup audit reports but cannot disable an agent — deliberate.
- `clean` measures skipped rules too, which costs a `du` per rule. Fine at 17
  rules; revisit if the registry grows into the dozens.
- `mk startup --json` and `mk rules --json` have no `schemaVersion`; only
  report and clean are pinned.

## Next task

The app exists and is tested. What remains is distribution and optional
surface:

1. **Notch overlay, only if wanted.** If the menu bar earns daily use, build a
   boringNotch-style panel as a separate project. It must consume the same
   `--json` boundary; do not move rules into Swift.
2. **Release path.** Developer ID signing and notarization before anyone
   downloads a binary, or document `make app` as a build-locally artifact.
3. **Remote and publish.** Create the GitHub remote, push, and publish the CLI
   to npm once the install path is final.

## Conventions

Plain ESM, no dependencies, small functions with injected `runCmd`,
`appRunning`, and `measure` hooks so everything is testable. Tests never touch
the real home directory; Swift tests use fixtures and a fake command runner.
Conventional commit messages. When the `--json` shape changes, update
`test/report-json.test.mjs` and the README "JSON boundary" section together;
bump `JSON_SCHEMA_VERSION` only for a removal or retype.
