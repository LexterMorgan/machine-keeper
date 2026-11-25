import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import path from "node:path";
import { run as defaultRun } from "./exec.mjs";

export async function readPlist(file, { runCmd = defaultRun } = {}) {
  const result = await runCmd("plutil", ["-convert", "json", "-o", "-", file]);
  if (!result.ok) {
    return null;
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    return null;
  }
}

export function programOf(plist) {
  if (!plist || typeof plist !== "object") {
    return null;
  }
  if (typeof plist.Program === "string") {
    return plist.Program;
  }
  if (Array.isArray(plist.ProgramArguments) && typeof plist.ProgramArguments[0] === "string") {
    return plist.ProgramArguments[0];
  }
  return null;
}

/**
 * "missing" means the plist points at an absolute program path that no longer
 * exists — the classic uninstalled-app leftover. Bare command names and
 * missing plists stay "unknown" rather than being guessed.
 */
export function orphanStatus(program, { exists = existsSync } = {}) {
  if (!program || !program.startsWith("/")) {
    return "unknown";
  }
  return exists(program) ? "present" : "missing";
}

export async function auditDirectory(dir, { runCmd, exists, readPlistFn } = {}) {
  let names = [];
  try {
    names = (await readdir(dir)).filter((name) => name.endsWith(".plist"));
  } catch {
    return [];
  }

  const rows = [];
  for (const name of names) {
    const file = path.join(dir, name);
    const plist = await (readPlistFn ?? ((target) => readPlist(target, { runCmd })))(file);
    const program = programOf(plist);
    rows.push({
      label: name.replace(/\.plist$/, ""),
      file,
      program,
      status: orphanStatus(program, { exists }),
    });
  }
  return rows.sort((a, b) => a.label.localeCompare(b.label));
}

export async function loginItems({ runCmd = defaultRun } = {}) {
  const script =
    'tell application "System Events" to get the name of every login item';
  const result = await runCmd("osascript", ["-e", script]);
  if (!result.ok) {
    return null;
  }
  const text = result.stdout.trim();
  return text === "" ? [] : text.split(",").map((name) => name.trim()).filter(Boolean);
}

export async function brewServices({ runCmd = defaultRun } = {}) {
  const result = await runCmd("brew", ["services", "list"]);
  if (!result.ok) {
    return null;
  }
  const lines = result.stdout.trim().split("\n").slice(1).filter(Boolean);
  return lines
    .map((line) => line.trim().split(/\s+/))
    .filter((columns) => columns.length >= 2)
    .map((columns) => ({ name: columns[0], status: columns[1] }));
}

export async function auditStartup({ home, runCmd = defaultRun, exists = existsSync, readPlistFn } = {}) {
  const [userAgents, systemAgents, systemDaemons, logins, services] = await Promise.all([
    auditDirectory(path.join(home, "Library/LaunchAgents"), { runCmd, exists, readPlistFn }),
    auditDirectory("/Library/LaunchAgents", { runCmd, exists, readPlistFn }),
    auditDirectory("/Library/LaunchDaemons", { runCmd, exists, readPlistFn }),
    loginItems({ runCmd }),
    brewServices({ runCmd }),
  ]);

  return {
    userAgents,
    systemAgents,
    systemDaemons,
    loginItems: logins,
    brewServices: services,
  };
}
