import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { clean } from "../src/clean.mjs";
import { run } from "../src/exec.mjs";
import { findInstallers } from "../src/installers.mjs";

const rule = (overrides = {}) => ({
  id: "test-cache",
  title: "test cache",
  kind: "delete",
  paths: ["Library/Caches/test-cache"],
  risk: "rebuild",
  ...overrides,
});

async function makeHome() {
  return mkdtemp(path.join(os.tmpdir(), "mk-home-"));
}

async function seed(home, relative, bytes = 200_000) {
  const target = path.join(home, relative);
  await mkdir(target, { recursive: true });
  await writeFile(path.join(target, "blob.bin"), Buffer.alloc(bytes));
  return target;
}

async function exists(target) {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
}

test("dry run reports bytes without deleting", async () => {
  const home = await makeHome();
  try {
    const target = await seed(home, "Library/Caches/test-cache");
    const result = await clean({ home, rules: [rule()], dryRun: true });

    assert.equal(result.dryRun, true);
    assert.equal(result.results[0].status, "would-remove");
    assert.ok(result.results[0].bytes > 0);
    assert.equal(await exists(target), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("--yes deletes and reports freed bytes", async () => {
  const home = await makeHome();
  try {
    const target = await seed(home, "Library/Caches/test-cache");
    const result = await clean({ home, rules: [rule()], dryRun: false });

    assert.equal(result.results[0].status, "removed");
    assert.ok(result.freedBytes > 0);
    assert.equal(await exists(target), false);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("a running app blocks its own rule", async () => {
  const home = await makeHome();
  try {
    const target = await seed(home, "Library/Caches/test-cache");
    const result = await clean({
      home,
      rules: [rule({ app: "Spotify" })],
      dryRun: false,
      appRunning: async () => true,
    });

    assert.equal(result.results[0].status, "skipped-app-running");
    assert.ok(result.results[0].bytes > 0);
    assert.equal(await exists(target), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("opt-in rules stay untouched unless included", async () => {
  const home = await makeHome();
  try {
    const target = await seed(home, "Library/Caches/test-cache");
    const result = await clean({
      home,
      rules: [rule({ optIn: true })],
      dryRun: false,
      includeOptIn: false,
    });

    assert.equal(result.results[0].status, "opt-in-skipped");
    assert.equal(await exists(target), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("missing targets are reported as missing", async () => {
  const home = await makeHome();
  try {
    const result = await clean({ home, rules: [rule()], dryRun: false });
    assert.equal(result.results[0].status, "missing");
    assert.equal(result.freedBytes, 0);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("command rules run their tool before removing leftovers", async () => {
  const home = await makeHome();
  try {
    const target = await seed(home, "Library/Caches/test-cache");
    const calls = [];
    const result = await clean({
      home,
      rules: [rule({ kind: "command", command: ["fakecache", "clean"] })],
      dryRun: false,
      runCmd: async (command, args) => {
        calls.push([command, ...(args ?? [])].join(" "));
        if (command === "du") {
          return run("du", args);
        }
        return { ok: true, stdout: "", stderr: "" };
      },
    });

    assert.ok(calls.includes("fakecache clean"));
    assert.equal(result.results[0].status, "removed");
    assert.equal(await exists(target), false);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("installers only match old files with allowed extensions", async () => {
  const home = await makeHome();
  try {
    const downloads = path.join(home, "Downloads");
    await mkdir(downloads, { recursive: true });
    const oldFile = path.join(downloads, "old.dmg");
    const newFile = path.join(downloads, "new.dmg");
    const notes = path.join(downloads, "notes.txt");
    await writeFile(oldFile, Buffer.alloc(1000));
    await writeFile(newFile, Buffer.alloc(1000));
    await writeFile(notes, Buffer.alloc(1000));

    const now = new Date("2026-11-25T00:00:00Z");
    const fortyDaysAgo = new Date(now.getTime() - 40 * 86_400_000);
    await (await import("node:fs/promises")).utimes(oldFile, fortyDaysAgo, fortyDaysAgo);

    const found = await findInstallers({
      home,
      rule: {
        kind: "installers",
        paths: ["Downloads"],
        extensions: [".dmg", ".zip"],
        days: 30,
      },
      now,
    });

    assert.equal(found.length, 1);
    assert.ok(found[0].absolute.endsWith("old.dmg"));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("installers handles a missing directory", async () => {
  const home = await makeHome();
  try {
    const found = await findInstallers({
      home,
      rule: { kind: "installers", paths: ["Downloads"], extensions: [".dmg"], days: 30 },
    });
    assert.deepEqual(found, []);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
