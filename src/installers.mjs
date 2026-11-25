import { readdir, stat } from "node:fs/promises";
import path from "node:path";
import { resolveRulePath } from "./guard.mjs";

const DAY_MS = 86_400_000;

/**
 * Find installer files in a rule's directory that are older than the rule's
 * age threshold. Top level only, regular files only, never recursive.
 */
export async function findInstallers({
  home,
  rule,
  now = new Date(),
  fileSystem = { readdir, stat },
}) {
  const directory = resolveRulePath(home, rule.paths[0]);
  const extensions = (rule.extensions ?? []).map((value) => value.toLowerCase());
  const maxAgeMs = (rule.days ?? 30) * DAY_MS;

  let entries;
  try {
    entries = await fileSystem.readdir(directory);
  } catch {
    return [];
  }

  const matches = [];
  for (const name of entries) {
    const lower = name.toLowerCase();
    if (!extensions.some((extension) => lower.endsWith(extension))) {
      continue;
    }
    const absolute = path.join(directory, name);
    let info;
    try {
      info = await fileSystem.stat(absolute);
    } catch {
      continue;
    }
    if (!info.isFile()) {
      continue;
    }
    const ageMs = now.getTime() - info.mtimeMs;
    if (ageMs < maxAgeMs) {
      continue;
    }
    matches.push({
      absolute,
      relative: path.posix.join(rule.paths[0], name),
      bytes: info.size,
      ageDays: Math.floor(ageMs / DAY_MS),
    });
  }

  return matches.sort((a, b) => b.bytes - a.bytes);
}
