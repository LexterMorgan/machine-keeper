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
  `schedule`. 31 rules; 83 Node tests passing.
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
  `mk clean --yes --only <safe ids> --json`. Its cleanup code contains no
  rules, target paths, or deletion logic; the bundle ships the engine's data
  and sources.
- App surface: Settings (refresh, menu-bar label, launch at login via
  `SMAppService`, notifications), an All Rules window (safe/blocked/opt-in
  groups, startup orphans with Reveal), explicit per-rule opt-in cleaning behind
  a confirmation, a header quick-actions menu, and the separate **Explore**
  window. The panel reports physical RAM used-of-total alongside swap and
  pressure. Notifications are off by default and request permission only from
  Settings.
- Explore is a read/Trash surface, not a rule builder: home-contained folder
  scan, combinable filters, 500-file cap with explicit truncation, skipped/
  unreadable reporting, regular files only, protected locations inspectable but
  Trash-disabled. It shares `policy.json` with the CLI guard, adds `~/Library`
  as an Explore-only protected root, and never writes rules or feeds Clean Safe
  or the scheduled report.
- 123 Swift tests passing (`swift test --package-path app`), written with Swift
  Testing because this machine's CommandLineTools has no XCTest.
- CI covers the CLI matrix (macOS + Ubuntu, Node 20 and 22) and, separately,
  builds and tests the app on macOS.
- `make app` hand-assembles `dist/MachineKeeper.app` (`Contents/MacOS`,
  `Info.plist`, and `Contents/Resources/cli`) and ad-hoc signs it; the bundle
  includes the CLI, rules, and engine sources, so no `npm link` is needed.
- The app runs its bundled CLI through a discovered Node 20+ runtime. `MK_BIN`
  overrides with an external `mk`; `MK_NODE` points at Node. If the bundled CLI
  exists but Node is absent, an installed external `mk` is still used; a missing
  runtime shows the error and setup hint instead of crashing.
- Not notarized, not published to npm. Pushed to GitHub at
  `github.com/LexterMorgan/machine-keeper`.

Verify before changing anything:

```bash
node --test test/*.test.mjs                  # must stay 83/83 or grow
node bin/mk.mjs report             # real, read-only output
node bin/mk.mjs clean              # dry run, nothing deleted
swift test --package-path app      # must stay 123/123 or grow
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
| `policy.json` | shared never-touch policy for the CLI guard and Explore |
| `rules.default.json` | the allowlist; rules are data, not code |
| `test/` | 83 Node tests; temp homes only, no real-home writes |
| `test/report-json.test.mjs` | contract test: pins the literal `schemaVersion` and the report/clean `--json` shapes |
| `app/` | SwiftPM package: `MkBar` menu-bar executable, `MkBarCore` logic, Swift tests |
| `app/README.md` | app architecture, state model, safety, and design narration |
| `app/Sources/MkBar/` | panel, Settings, All Rules, Explore, settings/notifications, menu-bar scenes |
| `app/Sources/MkBarCore/` | CLI bridge, report summary, process runner, Explore scan/Trash/policy |
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
- **The app is a face for cleanup, not an engine.** Swift cleanup code contains
  no rule definitions, target paths, or deletion logic. It reads
  `mk report --json`, previews `mk clean --json`, and deletes only through
  `mk clean --yes --only <ids> --json` with ids the report returned. Choosing
  safe rows is allowed; inventing ids or paths is not.
- **Explore is separate and never becomes cleanup.** It scans a home-contained
  folder and moves only selected regular files to native Trash. No Explore
  result is written to rules, passed to `mk clean`, included in Clean Safe, or
  used by the scheduled report. It shares the CLI's `neverTouch` policy through
  `policy.json` and adds `~/Library` as Explore-only protection.
- **Opt-in deletion is explicit.** `--include-opt-in` is sent only for a single
  opt-in rule the user selected in All Rules, after a confirmation whose default
  is Cancel. Clean safe filters opt-in ids and never sends the flag.

## Decisions already made

1. **The CLI is the cleanup engine; the GUI is a cleanup face.** Implemented
   in `app/`: cleanup shells out to `mk report --json` and `mk clean --json`
   and never reimplements rules, paths, or cleanup deletion. Explore is a
   separate Trash-only surface, not a second cleanup engine.
2. **The JSON boundary is versioned and additive.** `schemaVersion` is `1`
   (`src/schema.mjs`); bump it only for a removal or retype. Consumers ignore
   unknown keys. `test/report-json.test.mjs` and the README "JSON boundary"
   section move together with any shape change.
3. **Menu-bar app first, notch panel later.** The `MenuBarExtra` panel (disk,
   swap, pressure dot, top three reclaimables, orphan count, Refresh, Preview
   clean, Clean safe) plus Explore is the useful 90%. A boringNotch-style
   overlay is a separate, riskier project.
4. **No Xcode on this machine.** Only CommandLineTools, Swift 6.0.3, macOS SDK
   15.2, arm64, macOS 15 target. SwiftPM (`swift build`) plus a hand-written
   `.app` bundle (`make app`, `Info.plist` with `LSUIElement`); ad-hoc signing
   is fine, notarization is out of scope. Tests use Swift Testing because
   CommandLineTools ships no XCTest.
5. **Resolve the runtime per call, not at launch.** A GUI does not inherit a
   shell `PATH`, so `MK_BIN` wins, then the bundled CLI through a discovered
   Node, then an external `mk` in known install directories. Resolving inside
   each command means installing Node or `mk` later works without a relaunch.
6. **macOS-first.** Linux is welcome later; the rule model and metrics would
   need separate path/command implementations, not a rewrite.

## Open cleanup audit findings (tracked separately from Explore)

These are still open; Explore does not address them, and they are not
duplicated as ordinary gaps below.

1. **TOCTOU between cleanup validation and removal/command.** `clean` resolves
   `realpath` immediately before acting, but Node's recursive `rm` has no
   directory-fd/no-follow mode. A hostile concurrent path swap in the final
   window is not prevented; the documented assumption is no concurrent attacker
   with write access to the home. Explore has its own analogous final-check/
   `trashItem` race, documented separately.
2. **Command rules inherit the tool environment/config.** `PIP_CACHE_DIR`,
   `UV_CACHE_DIR`, `GOMODCACHE`, `.npmrc` cache settings, and similar can
   redirect an external tool outside the declared paths. The shipped commands
   were reviewed against defaults, but a custom environment is outside the
   cleanup allowlist guarantee. The CLI also exits 0 on a per-rule clean error;
   the JSON carries it.

## Known gaps

- **Not notarized.** `make app` ad-hoc signs; a downloadable build needs a
  Developer ID and notarization, or users build it locally.
- **No npm publish.** `github.com/LexterMorgan/machine-keeper` is the home;
  neither the CLI nor the app is on npm yet.
- **Node is not bundled.** The app ships `mk` and the rules but needs Node 20+
  on the machine; `MK_NODE` handles a nonstandard install. A true zero-setup
  build would embed Node and add roughly 100 MB plus signing work.
- **Launch at login is untested on this ad-hoc build.** The Settings toggle uses
  `SMAppService.mainApp`; macOS may require a signed bundle and Login Items
  approval, and the UI surfaces the error if registration fails.
- **Notifications are permission-gated.** They are off by default, request
  permission only from Settings, and were not delivered in automated checks; a
  bare `swift run` no-ops because `UNUserNotificationCenter` needs an app bundle.
- **Notch panel deferred.** The menu bar plus Settings/All Rules/Explore
  windows are the surfaces for now.
- **A cancelled or timed-out clean is not transactional.** The runner signals
  the child's whole process group on timeout (SIGTERM, grace, SIGKILL), keeps
  the leader unreaped until after the group signal so a helper that ignored
  SIGTERM cannot survive or let the group ID be reused, then reaps it before
  reporting the timeout. It still does not observe Swift task cancellation, a
  killed clean can stop half-done with no rollback, and a descendant that
  deliberately detaches into a new process group can escape. The app says a
  timed-out clean may be partial; re-run to finish.
- **Explore's final validation is not atomic with Trash.** It rechecks
  canonical home/root/parent, file type, identity, size, and mtime immediately
  before `FileManager.trashItem`, but `FileManager` has no atomic
  "trash exactly this inode" operation. A path swapped in the tiny window is
  not detected. It never permanently deletes.
- **Explore is capped at 500 matching files.** The UI says the list is
  incomplete and asks for narrower filters; it does not paginate.
- **Explore's live menu-bar UI flow is verified separately from unit tests.**
  Automated tests cover scan/filter/cancel/stale/selection/protected/trash
  outcomes; interactive NSOpenPanel and window behavior require the live check.
  The case-sensitive containment test runs locally on a disposable
  case-sensitive APFS image; it will fail clearly (not silently skip) if
  `hdiutil` cannot create/mount one on another host. Scan-root and pre-Trash
  directory metadata pass only when both `isHidden` and `isPackage` are
  explicitly false; nil or a thrown lookup is rejected/skipped. This is covered
  through both production service entry points with injected readers.
- **Stale safe ids fail closed.** The app sends the ids from its last report; if
  the registry changed since, the CLI rejects the request before deleting
  anything. That is a visible error and one Refresh away, not a partial clean.
- Startup audit reports but cannot disable an agent — deliberate.
- `clean` measures skipped rules too, which costs a `du` per rule. Fine at 31
  rules (~6 s for a full report here); revisit if the registry grows further.
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
3. **Publish.** The GitHub remote exists; publish the CLI to npm once the
   install path is final.

## Conventions

Plain ESM, no dependencies, small functions with injected `runCmd`,
`appRunning`, and `measure` hooks so everything is testable. Tests never touch
the real home directory; Swift tests use fixtures and a fake command runner.
Conventional commit messages. When the `--json` shape changes, update
`test/report-json.test.mjs` and the README "JSON boundary" section together;
bump `JSON_SCHEMA_VERSION` only for a removal or retype.
