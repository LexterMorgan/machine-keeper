import { stat } from "node:fs/promises";
import { parseDuKilobytes } from "./bytes.mjs";
import { run as defaultRun } from "./exec.mjs";
import { resolveRulePath } from "./guard.mjs";

export async function pathExists(target) {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
}

/** Bytes used by one file or directory, or 0 when it is missing. */
export async function measureBytes(target, { runCmd = defaultRun } = {}) {
  if (!(await pathExists(target))) {
    return 0;
  }
  const result = await runCmd("du", ["-sk", target]);
  return result.ok ? parseDuKilobytes(result.stdout) : 0;
}

export function ruleTargets(home, rule) {
  return rule.paths.map((relPath) => ({
    relPath,
    absolute: resolveRulePath(home, relPath),
  }));
}

export async function measureRule(home, rule, { runCmd = defaultRun } = {}) {
  let total = 0;
  const parts = [];
  for (const target of ruleTargets(home, rule)) {
    const bytes = await measureBytes(target.absolute, { runCmd });
    if (bytes > 0) {
      parts.push({ ...target, bytes });
      total += bytes;
    }
  }
  return { totalBytes: total, parts };
}

export async function isAppRunning(app, { runCmd = defaultRun } = {}) {
  const result = await runCmd("pgrep", ["-f", `${app}.app/Contents/MacOS`]);
  return result.ok && result.stdout.trim() !== "";
}
