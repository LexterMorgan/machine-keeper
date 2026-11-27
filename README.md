# machine-keeper

**Keep a small Mac from filling up.** Audit disk, swap pressure, and startup items; reclaim the caches that developers actually accumulate — by allowlist, dry-run first, no `sudo`, no "cleaner" magic.

Built for 8 GB and 16 GB machines, where 15–30 GB of dead caches is the difference between "fine" and "constantly swapping".

```
$ mk

machine-keeper 0.1.0 — 2026-11-25 14:12

Disk     137 GB used · 49.1 GB free (74% full)
Memory   RAM 12.4 GB of 16.0 GB · swap 2.58 GB of 4.00 GB · pressure warning · compressor 2.94 GB

Reclaimable  1.94 GB across 6 rules
  codex-runtimes           1.26 GB   rebuild
  brew-cleanup              299 MB   safe
  npm-cache                 283 MB   rebuild
  npx-cache                56.1 MB   rebuild
  chrome-cache             42.8 MB   rebuild
  pip-cache                8.65 MB   rebuild
  spotify-cache            8.32 GB   quit Spotify first
  brave-cache              4.03 GB   quit Brave Browser first

Opt-in  148 MB (excluded unless asked)
  huggingface-cache         141 MB   Downloaded models are removed and re-download later.
  stale-installers         6.44 MB   Installer files older than 30 days; re-downloadable.

Startup  10 user agents · 3 system agents · 9 daemons · 5 login items
  orphaned: com.valvesoftware.steamclean

Next  mk clean            dry run
      mk clean --yes      delete
```

## Why

Developer machines collect duplicates: an npm cache, an npx cache, a uv cache, a pip cache, a pnpm store, Playwright browsers, Xcode DerivedData, and a browser cache per browser. None of it is user data, all of it is rebuildable, and it regrows quietly. On a 245 GB laptop, two years of `npm install` is tens of gigabytes.

Cache growth is also uneven. One machine in this project's history had 25 GB of caches, a 12 GB Spotify cache, 16 GB of residue from an uninstalled editor, and 9 GB of swap in use on 8 GB of RAM. None of that is unusual; it is just invisible.

machine-keeper makes it visible, then removes only what it can name.

## Install

Requires macOS and Node.js 20 or newer.

```bash
git clone https://github.com/LexterMorgan/machine-keeper.git
cd machine-keeper
node bin/mk.mjs            # or: npm link, then just `mk`
```

No dependencies. Nothing is installed globally unless you link it.

## Usage

```bash
mk                       # report: disk, memory, caches, startup items
mk report --json         # same, machine-readable

mk clean                 # dry run: what would be removed
mk clean --yes           # remove the included rules
mk clean --only npm-cache,uv-cache
mk clean --include-opt-in --yes

mk startup               # launch agents, daemons, login items
mk rules                 # every rule with kind and risk

mk schedule --install    # monthly report via launchd (never cleans)
mk schedule --uninstall
```

## Menu-bar app (optional)

`app/` is a thin SwiftUI menu-bar app. By default it runs `mk report --json`
every 60 seconds and renders that result: disk, RAM and swap, memory pressure, the top
reclaimable rules, and orphaned startup items. Settings can switch to 5 minutes
or manual refresh, change the menu-bar label, register a login item, and enable
low-disk or critical-pressure notifications.

An **All Rules** window lists every measured rule grouped as safe, blocked by a
running app, or opt-in, plus orphaned startup entries with a Reveal action.
Opt-in rules are cleaned only from that window, one rule at a time, behind an
explicit confirmation that spells out the user-files risk; clean safe never
passes `--include-opt-in`. Every delete is still `mk clean ... --json`, whose
result the app decodes. The app does not reimplement rules, paths, or deletion.

Requires macOS 15, a Swift 6 toolchain, and Node.js 20 or newer at runtime.
CommandLineTools is enough — there is no Xcode project and `xcodebuild` is not
used. The app bundles its own copy of `mk`, the rules, and the engine sources,
so `npm link` is no longer required.

```bash
make app                  # release build + hand-assembled bundle in dist/
open dist/MachineKeeper.app

make app-run              # same, launched from the terminal
make app-test             # Swift tests
MK_NODE=/path/to/node make app-run
MK_BIN=/path/to/mk make app-run
```

The bundle is `LSUIElement` (menu bar only, no Dock icon), ad-hoc signed, and
not notarized; build it locally. It runs its bundled CLI through a discovered
Node 20+ runtime. `MK_NODE` points at a Node install the locator cannot find;
`MK_BIN` still overrides the bundled CLI with an external `mk`. If neither Node
nor an external `mk` is found, the app shows the error and setup hint instead
of crashing. See [app/README.md](app/README.md) for the architecture, state
model, and design decisions.

### Explore is separate from cleanup

The menu-bar app's **Explore** window searches a folder inside your home for
regular files, with combinable filename, extension, minimum-size, and
last-modified filters. It can move individually selected files to the macOS
Trash. It never writes a rule, never appears in `mk clean`, Clean Safe, or the
scheduled report, and permanent deletion is not implemented.

Explore uses the same `policy.json` as the CLI guard for the registry
never-touch list, and additionally treats `~/Library` as read-only. Symlinks,
hidden entries, `.app` bundles, and packages are skipped during traversal.
Protected folders remain inspectable, but Trash is disabled there. Every
selected file is revalidated by canonical parent path, regular-file type,
device/inode, size, and mtime immediately before the native Trash call; files
that moved or changed are skipped and reported. Results are capped at 500 and
the UI says when the list is incomplete.

## Safety model

This is a deletion tool, so the boring parts are the design:

- **Allowlist, not discovery.** Only home-relative paths named in `rules.default.json` are touched. There is no "find big files" mode.
- **Dry run by default.** `--yes` is required to delete; without it `mk clean` only measures.
- **Running apps are skipped.** A Spotify or Brave cache is not deleted while the app holds it.
- **Opt-in for anything with user value.** Uninstalled-app residue, model caches, Maven's local repository, and old installers are excluded unless `--include-opt-in` is passed. Downloads is scanned at the top level only.
- **Protected paths, checked twice.** Registry validation rejects Documents, Desktop, Pictures, Projects, `.ssh`, `Library/Containers`, and similar. Immediately before a command or removal, cleanup resolves `realpath` for the actual home and target: a target that contains a protected directory, a symlinked parent into protected data, or a path that escapes home is refused. Unverifiable targets fail closed. This applies per installer file as well as recursive cache targets.
- **Commands fail closed.** A command rule that exits non-zero aborts that rule; the tool does not fall back to `rm -rf`. The shipped commands were reviewed as target-scoped; Homebrew is now a plain cache deletion instead of `brew cleanup`, which reaches installed versions beyond its declared target. Commands run with the current tool environment, so custom cache variables or config can redirect a tool outside its declared path; the default configurations were reviewed, but a custom environment is outside the allowlist guarantee.
- **No `sudo`, ever.** Everything lives under your home directory. Anything needing root is out of scope.
- **No network.** The tool never phones home, never uploads a report.

The only permanent loss is what the rule says: rebuildable caches, and — when you opt in — residue and installers. There is a small TOCTOU window between the final realpath check and the filesystem call or command. Node's recursive `rm` has no directory-fd/no-follow mode, so a hostile process that swaps a validated path for a symlink in that window is not defeated; the tool assumes no concurrent attacker with write access to the same home. Commands may also have effects within their tool's own model; only the reviewed commands above are shipped.

**Explore** has its own matching race: its last `lstat` identity check and the native Trash call are separate operations. It rechecks canonical home/root/parent, type, identity, size, and mtime immediately before each move, but cannot make the move atomic with that check. It never permanently deletes.

## Rules

Defaults use home-relative, standard cache paths, so one registry works across
Macs: a missing tool or cache simply measures zero. Use
`MK_RULES=/path/to/rules.json` to replace the registry for a machine with
unusual paths or extra tools.

| Rule | Default | What it removes |
|---|---|---|
| `npm-cache` | on | `~/.npm/_cacache` via `npm cache clean --force` |
| `npx-cache` | on | `~/.npm/_npx` |
| `uv-cache` | on | `~/.cache/uv` or `~/Library/Caches/uv` via `uv cache clean` |
| `pip-cache` | on | `~/Library/Caches/pip` via `pip cache purge` |
| `pnpm-store` | on | prunes `~/Library/pnpm/store` |
| `yarn-cache` | on | Yarn 1 and Berry caches |
| `bun-cache` | on | `~/.bun/install/cache` |
| `deno-cache` | on | Deno module cache |
| `go-cache` | on | Go build cache and module cache (`go clean -modcache`) |
| `cargo-cache` | on | Cargo registry and git caches |
| `gradle-cache` | on | Gradle caches and wrapper distributions |
| `maven-cache` | opt-in | `~/.m2/repository`; may hold unpublished locally installed artifacts Maven cannot re-download |
| `swiftpm-cache` | on | `~/Library/Caches/org.swift.swiftpm` |
| `cocoapods-cache` | on | `~/Library/Caches/CocoaPods` |
| `playwright-browsers` | on | `~/Library/Caches/ms-playwright` or `~/.cache/ms-playwright` |
| `puppeteer-browsers` | on | Puppeteer browser downloads |
| `cypress-cache` | on | Cypress binary cache |
| `electron-cache` | on | Electron and electron-builder downloads |
| `xcode-derived-data` | on | `~/Library/Developer/Xcode/DerivedData` (app must be closed) |
| `brew-cleanup` | on | downloaded Homebrew cache only; installed versions untouched |
| `vscode-cache` | on | VS Code cache directories (app must be closed) |
| `cursor-cache` | on | Cursor cache directories (app must be closed) |
| `codex-runtimes` | on | `~/.cache/codex-runtimes` |
| `spotify-cache` | on | Spotify cache (app must be closed) |
| `brave-cache` | on | Brave caches (app must be closed) |
| `chrome-cache` | on | Chrome cache (app must be closed) |
| `codex-app-cache` | on | Codex cache (ChatGPT app must be closed) |
| `steam-residue` | opt-in | Steam data when Steam is uninstalled |
| `cursor-residue` | opt-in | Cursor data; intended for an uninstalled Cursor, and only when Cursor is not running |
| `huggingface-cache` | opt-in | downloaded models |
| `stale-installers` | opt-in | `.dmg`/`.pkg`/`.zip` in Downloads older than 30 days |

## Startup audit

`mk startup` lists user launch agents, system agents and daemons, login items, and Homebrew services, and flags plists whose `Program` no longer exists — the usual leftover when an app is dragged to the trash. It reports; it does not unload anything.

## JSON boundary

`mk report --json` is the interface for faces such as the menu-bar app. It is
versioned with `schemaVersion` (currently `1`), and changes are additive.

Required top-level fields:

| field | type | notes |
|---|---|---|
| `schemaVersion` | number | current `1`; bumped only for a removal or type change |
| `generatedAt` | string | ISO 8601 |
| `home` | string | home directory the report was built against |
| `disk` | object or null | `totalBytes`, `usedBytes`, `freeBytes`, `percent` (string) |
| `memory` | object or null | `totalBytes` (physical RAM), `usedBytes` (app + wired + compressor, or null when the counters are absent), `appBytes` (anonymous minus purgeable), `cachedBytes` (file-backed), `swap` (`totalBytes`, `usedBytes`, `freeBytes`), `pressureLevel` (1 normal, 2 warning, 4 critical; other values unknown), `pressureLabel`, `wiredBytes`, `compressorBytes`, `freeBytes` |
| `rows` | array | every rule, opt-in included |
| `optInRows` | array | subset of `rows` with `optIn: true` |
| `sweepableBytes` | number | non-opt-in rules that are not running |
| `blockedBytes` | number | non-opt-in rules currently blocked by a running app |
| `optInBytes` | number | bytes in opt-in rules |
| `startup` | object | `userAgents`, `systemAgents`, `systemDaemons` arrays of `{label, file, program, status}`; `loginItems` array or null; `brewServices` array or null; `status` is `present`, `missing`, or `unknown` |

Each row is `{id, title, risk, optIn, app, appRunning, reclaim, bytes, files}`:
`app` is the owning app's name or null; `appRunning` says whether it is running
now, which is what blocks the rule. `reclaim` is the human note shown next to
the rule.

`disk` and `memory` are null when measurement fails; the report still returns
rows. Bytes are JSON numbers in the 64-bit integer range, not strings.

`mk clean --json` (dry run) and `mk clean --yes --json` (real run) return
`{schemaVersion, dryRun, results, freedBytes}`. Each result is
`{id, title, bytes, status, error?}` with status `removed`, `would-remove`,
`skipped-app-running`, `opt-in-skipped`, `error`, or `missing`. Adding
`--include-opt-in` widens the selection to opt-in rules; the app sends it only
for a rule the user selected explicitly in All Rules, and never for Clean safe.

Consumers must ignore unknown keys. The exact contract is pinned by
`test/report-json.test.mjs`; change that test and this section together.

## Roadmap

- Notch-overlay panel, if the menu bar proves useful enough to want at a glance.
- Linux support: same rule model, different paths and metrics.
- More rule coverage: Docker/Colima images, simulator runtimes, additional language caches.

## Contributing

Rules are data. To add one, edit `rules.default.json` and run `npm test`; the loader validates ids, kinds, risks, and paths. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
