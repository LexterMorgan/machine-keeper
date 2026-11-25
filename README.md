# machine-keeper

**Keep a small Mac from filling up.** Audit disk, swap pressure, and startup items; reclaim the caches that developers actually accumulate — by allowlist, dry-run first, no `sudo`, no "cleaner" magic.

Built for 8 GB and 16 GB machines, where 15–30 GB of dead caches is the difference between "fine" and "constantly swapping".

```
$ mk

machine-keeper 0.1.0 — 2026-11-25 14:12

Disk     137 GB used · 49.1 GB free (74% full)
Memory   swap 2.58 GB of 4.00 GB · pressure warning · compressor 2.94 GB

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

## Safety model

This is a deletion tool, so the boring parts are the design:

- **Allowlist, not discovery.** Only home-relative paths named in `rules.default.json` are touched. There is no "find big files" mode.
- **Dry run by default.** `--yes` is required to delete; without it `mk clean` only measures.
- **Running apps are skipped.** A Spotify or Brave cache is not deleted while the app holds it.
- **Opt-in for anything with user value.** Uninstalled-app residue, model caches, and old installers are excluded unless `--include-opt-in` is passed. Downloads is scanned at the top level only.
- **Protected paths.** Rules cannot point at Documents, Desktop, Pictures, Projects, `.ssh`, `Library/Containers`, or similar. A rule that tries fails validation at startup.
- **No `sudo`, ever.** Everything lives under your home directory. Anything needing root is out of scope.
- **No network.** The tool never phones home, never uploads a report.

The only permanent loss is what the rule says: rebuildable caches, and — when you opt in — residue and installers.

## Rules

| Rule | Default | What it removes |
|---|---|---|
| `npm-cache` | on | `~/.npm/_cacache` via `npm cache clean --force` |
| `npx-cache` | on | `~/.npm/_npx` |
| `uv-cache` | on | `~/.cache/uv` via `uv cache clean` |
| `pip-cache` | on | `~/Library/Caches/pip` via `pip cache purge` |
| `pnpm-store` | on | prunes `~/Library/pnpm/store` |
| `playwright-browsers` | on | `~/Library/Caches/ms-playwright` |
| `codex-runtimes` | on | `~/.cache/codex-runtimes` |
| `xcode-derived-data` | on | `~/Library/Developer/Xcode/DerivedData` |
| `brew-cleanup` | on | old Homebrew versions and downloads |
| `spotify-cache` | on | Spotify cache (app must be closed) |
| `brave-cache` | on | Brave caches (app must be closed) |
| `chrome-cache` | on | Chrome cache (app must be closed) |
| `codex-app-cache` | on | Codex cache (ChatGPT app must be closed) |
| `steam-residue` | opt-in | Steam data when Steam is uninstalled |
| `cursor-residue` | opt-in | Cursor data when Cursor is uninstalled |
| `huggingface-cache` | opt-in | downloaded models |
| `stale-installers` | opt-in | `.dmg`/`.pkg`/`.zip` in Downloads older than 30 days |

## Startup audit

`mk startup` lists user launch agents, system agents and daemons, login items, and Homebrew services, and flags plists whose `Program` no longer exists — the usual leftover when an app is dragged to the trash. It reports; it does not unload anything.

## Roadmap

- Menu-bar app: `mk report --json` rendered as a small SwiftUI panel with live disk and swap.
- Linux support: same rule model, different paths and metrics.
- More rule coverage: Docker/Colima images, simulator runtimes, additional language caches.

## Contributing

Rules are data. To add one, edit `rules.default.json` and run `npm test`; the loader validates ids, kinds, risks, and paths. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
