# Handover

State of the project for the next person or session. Keep this current; it is
the cheapest way to transfer context that would otherwise live in a chat log.

Last updated: 2026-11-25, commit `870ae6d`.

## What this is

`machine-keeper` audits and reclaims disk space on macOS developer machines.
It is a CLI (`mk`), published under MIT, written for 8 GB and 16 GB laptops
where accumulated caches are the difference between usable and swapping.

Node 20+, no runtime dependencies, no build step, no network, no sudo.

## Status

- CLI complete and working: `report`, `clean`, `startup`, `rules`, `schedule`.
- 17 rules; 34 tests passing; CI matrix macOS + Ubuntu, Node 20 and 22.
- Not published to npm. No git remote configured yet.
- Only one commit; the whole project was written in a single session.

Verify before changing anything:

```bash
node --test test/          # must stay 34/34 or grow
node bin/mk.mjs report     # real, read-only output
node bin/mk.mjs clean      # dry run, nothing deleted
```

## Layout

| Path | Responsibility |
|---|---|
| `bin/mk.mjs` | entry point; forwards argv, maps errors to exit codes |
| `src/cli.mjs` | arg parsing, commands, human output, `--json` |
| `src/rules.mjs` | registry validation, `--only` selection, opt-in filtering |
| `src/guard.mjs` | path guard: home-relative only, protected locations refused |
| `src/report.mjs` | disk + memory + per-rule footprint; pure of side effects |
| `src/clean.mjs` | dry-run by default; app-quit guard; per-rule isolation |
| `src/startup.mjs` | launch agents/daemons, orphan detection, login items |
| `src/schedule.mjs` | monthly launchd report (never cleans) |
| `rules.default.json` | the allowlist; rules are data, not code |
| `test/` | 34 tests; temp homes only, no real-home writes |

## Invariants (do not weaken)

- Deletion targets are **allowlisted**, never discovered by scanning.
- **Dry run is the default**; `--yes` is required to delete anything.
- A cache is skipped while its owning app is running.
- Anything with user value is `optIn` and marked `risk: "user-files"`.
- No `sudo`, no system paths, no recursion into Downloads, no network.
- The guard refuses `Documents`, `Desktop`, `Pictures`, `Projects`, `.ssh`,
  `Library/Containers`, `Library/Mobile Documents` even if a rule names them.

## Decisions already made

1. **The CLI is the engine; any GUI is a face.** A native app must shell out to
   `mk report --json` and `mk clean --yes --only <ids>`. It must not
   reimplement rules, paths, or deletion logic.
2. **Menu-bar app first, notch panel later.** A `MenuBarExtra`/`NSStatusItem`
   panel (disk, swap, pressure dot, top reclaimables, orphan count, Refresh,
   Preview clean, Clean safe) is the useful 90% and validates whether anyone
   wants to stare at the numbers. A boringNotch-style overlay panel is a
   separate, riskier project.
3. **No Xcode on this machine.** Only CommandLineTools, Swift 6.0.3, macOS SDK
   15.2, arm64, macOS 15 target. That means SwiftPM (`swift build`) plus a
   hand-written `.app` bundle (`make app`, `Info.plist` with `LSUIElement`).
   Unsigned local builds are fine; notarization is out of scope for now.
4. **macOS-first.** Linux is welcome later; the rule model and metrics would
   need separate path/command implementations, not a rewrite.

## Known gaps

- **The `--json` shape is not pinned.** No schema test; a change to
  `report.mjs` can silently break a consumer. Add a schema/contract test before
  building a GUI against it.
- No git remote (`github.com/LexterMorgan/machine-keeper` is the intended home).
- No npm publish; `npm link` is the intended install path.
- Startup audit reports but cannot disable an agent — deliberate.
- `clean` measures skipped rules too, which costs a `du` per rule. Fine at 17
  rules; revisit if the registry grows into the dozens.

## Next task

Build the menu-bar app in `app/`:

- SwiftUI app, `LSUIElement` (no Dock icon), menu-bar only.
- Refresh `mk report --json` every ~60 s off the main thread; never block the
  menu on a process.
- Show: disk used/free, swap used/total, pressure dot (green/yellow/red from
  `pressureLevel` 1/2/4), top three reclaimable rules, orphan count.
- Actions: Refresh, Preview clean (dry run, show the diff), Clean safe
  (non-opt-in, non-running rules only).
- Degrade gracefully when `mk` is not on PATH: show a one-line setup hint.
- Keep the engine untouched; additive JSON fields are acceptable.

## Conventions

Plain ESM, no dependencies, small functions with injected `runCmd`,
`appRunning`, and `measure` hooks so everything is testable. Tests never touch
the real home directory. Conventional commit messages.
