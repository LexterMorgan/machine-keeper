# Contributing

## The short version

Rules are data. Add a row to `rules.default.json`, cover it with a test if the
rule is not a plain `delete`, run `npm test`, open a pull request.

## Adding a rule

Every rule must answer three questions:

1. **What exactly is removed?** `paths` are relative to the user's home. No
   absolute paths, no `~`, no globs. Prefer the narrowest directory that the
   owning tool rebuilds itself.
2. **What does it cost the user?** `risk` is one of `safe` (nothing to lose),
   `rebuild` (tool re-downloads), or `user-files` (anything the user might
   miss — those must also set `"optIn": true`).
3. **How does the user get it back?** `reclaim` is one sentence, written for
   the person reading the report.

Rules that must never be added:

- Anything outside the user's home directory.
- Anything under `Documents`, `Desktop`, `Pictures`, `Projects`, `.ssh`,
  `Library/Containers`, or `Library/Mobile Documents`; the guard rejects them.
- Anything that needs `sudo`.
- Anything that guesses what is safe by scanning for large files.

If an app owns the cache, set `"app": "App Name"`. The cleaner skips that rule
while the app is running.

If a tool has a first-party cache command, use `"kind": "command"` and name it.
Tool-aware cleanup is safer than deleting a cache directory from under a
program that expects its index to exist.

## Testing

```bash
node --test test/
```

Unit tests must not touch the real home directory. Use `mkdtemp` and pass
`home` explicitly; every module accepts injected `runCmd`, `appRunning`, and
`measure` hooks for exactly this reason.

## Style

Plain ESM, no dependencies, no build step. Node 20+. Prefer a small function
with an injected dependency over a framework.
