import { rm } from "node:fs/promises";
import { run as defaultRun } from "./exec.mjs";
import { assertDeletable } from "./guard.mjs";
import { findInstallers } from "./installers.mjs";
import { JSON_SCHEMA_VERSION } from "./schema.mjs";
import {
  isAppRunning,
  measureBytes,
  pathExists,
  ruleTargets,
} from "./targets.mjs";

const REMOVE_OPTIONS = { recursive: true, force: true, maxRetries: 2 };

async function sumTargets(targets, measure, runCmd) {
  let total = 0;
  for (const target of targets) {
    total += await measure(target.absolute, { runCmd });
  }
  return total;
}

/**
 * Apply rules. Dry-run unless the caller explicitly opts in.
 *
 * Every rule is evaluated independently: a running app skips its cache, an
 * opt-in rule stays out until included, and a failure on one rule never stops
 * the rest. Sizes are measured for skipped rules too, so a dry run shows what
 * is blocked rather than just hiding it.
 */
export async function clean({
  home,
  rules,
  dryRun = true,
  includeOptIn = false,
  runCmd = defaultRun,
  now = () => new Date(),
  appRunning = isAppRunning,
  remove = (target, options) => rm(target, options),
  measure = measureBytes,
}) {
  const results = [];

  for (const rule of rules) {
    const base = { id: rule.id, title: rule.title, bytes: 0, status: "missing" };

    try {
      const isInstallers = rule.kind === "installers";
      const targets = isInstallers ? [] : ruleTargets(home, rule);
      const files = isInstallers
        ? await findInstallers({ home, rule, now: now() })
        : [];
      const before = isInstallers
        ? files.reduce((sum, file) => sum + file.bytes, 0)
        : await sumTargets(targets, measure, runCmd);

      if (rule.optIn && !includeOptIn) {
        results.push({ ...base, bytes: before, status: "opt-in-skipped" });
        continue;
      }
      if (rule.app && (await appRunning(rule.app, { runCmd }))) {
        results.push({ ...base, bytes: before, status: "skipped-app-running" });
        continue;
      }
      if (before === 0) {
        results.push({ ...base, status: "missing" });
        continue;
      }
      if (dryRun) {
        results.push({ ...base, bytes: before, status: "would-remove" });
        continue;
      }

      if (isInstallers) {
        // Each installer is a separate file; validate every one before any
        // removal so a redirected directory cannot delete a partial set.
        for (const file of files) {
          await assertDeletable(home, file.absolute);
        }
        let removed = 0;
        for (const file of files) {
          // Re-check immediately before each file removal; a directory can be
          // swapped for a symlink after the batch validation above.
          if (!(await pathExists(file.absolute))) {
            continue;
          }
          await assertDeletable(home, file.absolute);
          await remove(file.absolute, { force: true });
          removed += file.bytes;
        }
        results.push({
          ...base,
          bytes: removed,
          status: removed > 0 ? "removed" : "missing",
        });
        continue;
      }

      // Validate before a tool-aware command can touch anything, then again
      // just before each recursive removal. Missing alternate paths are
      // normal (a rule may list several install locations) and measure zero;
      // do not turn them into a per-rule ENOENT. The second check narrows, but
      // does not eliminate, the validation/deletion race documented in README.
      for (const target of targets) {
        if (!(await pathExists(target.absolute))) {
          continue;
        }
        await assertDeletable(home, target.absolute);
      }

      if (rule.command) {
        // Tool-aware cleanup first (npm, uv, go, …). A failed command must not
        // fall through to rm: the tool may have left a cache in a state where
        // recursive deletion is unsafe.
        const commandResult = await runCmd(rule.command[0], rule.command.slice(1));
        if (!commandResult?.ok) {
          const code = commandResult?.code ?? "unknown";
          const detail = (commandResult?.stderr ?? "").trim();
          throw new Error(
            `cleanup command failed (${code})${detail ? `: ${detail}` : ""}`
          );
        }
      }
      for (const target of targets) {
        if (!(await pathExists(target.absolute))) {
          continue;
        }
        await assertDeletable(home, target.absolute);
        await remove(target.absolute, REMOVE_OPTIONS);
      }

      const after = await sumTargets(targets, measure, runCmd);
      const freed = Math.max(before - after, 0);
      results.push({ ...base, bytes: freed, status: "removed" });
    } catch (error) {
      results.push({ ...base, status: "error", error: error.message });
    }
  }

  return {
    schemaVersion: JSON_SCHEMA_VERSION,
    dryRun,
    results,
    freedBytes: results
      .filter((result) => result.status === "removed")
      .reduce((sum, result) => sum + result.bytes, 0),
  };
}
