import test from "node:test";
import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  rm,
  stat,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { clean } from "../src/clean.mjs";
import { containsProtectedRelative, isProtectedRelative } from "../src/guard.mjs";

async function makeHome() {
  return mkdtemp(path.join(os.tmpdir(), "mk-guard-home-"));
}

async function seed(home, relative, bytes = 256) {
  const target = path.join(home, relative);
  await mkdir(target, { recursive: true });
  const file = path.join(target, "blob.bin");
  await writeFile(file, Buffer.alloc(bytes));
  return file;
}

async function exists(target) {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
}

const rule = (overrides = {}) => ({
  id: "guard-test",
  title: "guard test",
  kind: "delete",
  paths: ["Library/Caches/guard-test"],
  risk: "rebuild",
  ...overrides,
});

test("a recursive target that contains protected data is refused", async () => {
  const home = await makeHome();
  try {
    const sentinel = await seed(home, "Library/Containers/secret", 1000);
    const calls = [];
    const result = await clean({
      home,
      rules: [rule({ paths: ["Library"] })],
      dryRun: false,
      measure: async () => 1,
      remove: async (...args) => calls.push(args),
    });

    assert.equal(result.results[0].status, "error");
    assert.match(result.results[0].error, /contains a protected location/);
    assert.equal(calls.length, 0);
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("a symlinked parent into protected data is refused", async () => {
  const home = await makeHome();
  try {
    const sentinel = await seed(home, "Library/Containers/secret", 1000);
    await symlink(
      path.join(home, "Library", "Containers"),
      path.join(home, "CachesLink"),
      "dir"
    );

    const calls = [];
    const result = await clean({
      home,
      rules: [rule({ paths: ["CachesLink"] })],
      dryRun: false,
      measure: async () => 1,
      remove: async (...args) => calls.push(args),
    });

    assert.equal(result.results[0].status, "error");
    assert.match(result.results[0].error, /protected location/);
    assert.equal(calls.length, 0);
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("a symlinked parent escaping the temporary home is refused", async () => {
  const home = await makeHome();
  const outside = await mkdtemp(path.join(os.tmpdir(), "mk-guard-outside-"));
  try {
    const sentinel = await seed(outside, "data", 1000);
    await symlink(outside, path.join(home, "CachesLink"), "dir");

    const calls = [];
    const result = await clean({
      home,
      rules: [rule({ paths: ["CachesLink"] })],
      dryRun: false,
      measure: async () => 1,
      remove: async (...args) => calls.push(args),
    });

    assert.equal(result.results[0].status, "error");
    assert.match(result.results[0].error, /escapes home/);
    assert.equal(calls.length, 0);
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  }
});

test("a redirected installers directory cannot delete protected files", async () => {
  const home = await makeHome();
  try {
    const protectedDir = path.join(home, "Library", "Containers", "secret");
    await mkdir(protectedDir, { recursive: true });
    const sentinel = path.join(protectedDir, "keep.dmg");
    await writeFile(sentinel, Buffer.alloc(1000));
    const fortyDaysAgo = new Date(Date.now() - 40 * 86_400_000);
    await utimes(sentinel, fortyDaysAgo, fortyDaysAgo);

    await symlink(protectedDir, path.join(home, "Downloads"), "dir");

    const calls = [];
    const result = await clean({
      home,
      rules: [
        rule({
          id: "installers",
          kind: "installers",
          paths: ["Downloads"],
          extensions: [".dmg"],
          days: 30,
        }),
      ],
      dryRun: false,
      remove: async (...args) => calls.push(args),
    });

    assert.equal(result.results[0].status, "error");
    assert.match(result.results[0].error, /protected location/);
    assert.equal(calls.length, 0);
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("a permitted cache still deletes", async () => {
  const home = await makeHome();
  try {
    const target = path.join(home, "Library", "Caches", "allowed");
    await seed(home, "Library/Caches/allowed", 1000);

    const result = await clean({
      home,
      rules: [rule({ paths: ["Library/Caches/allowed"] })],
      dryRun: false,
    });

    assert.equal(result.results[0].status, "removed");
    assert.equal(await exists(target), false);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("protected checks are case-insensitive and distinguish ancestors from caches", () => {
  assert.equal(isProtectedRelative("library/containers/app"), true);
  assert.equal(isProtectedRelative("Library/Caches/Google"), false);
  assert.equal(containsProtectedRelative("library"), true);
  assert.equal(containsProtectedRelative("Library/Caches"), false);
});

test("a protected target never reaches the tool-aware command", async () => {
  const home = await makeHome();
  try {
    const sentinel = await seed(home, "Library/Containers/secret", 1000);
    const calls = [];
    const result = await clean({
      home,
      rules: [
        rule({
          paths: ["Library"],
          kind: "command",
          command: ["should-not-run"],
        }),
      ],
      dryRun: false,
      measure: async () => 1,
      runCmd: async (command, args) => {
        calls.push([command, ...(args ?? [])].join(" "));
        return { ok: true, stdout: "", stderr: "" };
      },
      remove: async () => {},
    });

    assert.equal(result.results[0].status, "error");
    assert.match(result.results[0].error, /contains a protected location/);
    assert.deepEqual(calls, []);
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("the actual home is resolved when home is reached through a symlink", async () => {
  const realHome = await makeHome();
  const aliasParent = await mkdtemp(path.join(os.tmpdir(), "mk-guard-alias-"));
  const alias = path.join(aliasParent, "home");
  try {
    await symlink(realHome, alias, "dir");
    const target = path.join(realHome, "Library", "Caches", "allowed");
    await seed(realHome, "Library/Caches/allowed", 500);

    const result = await clean({
      home: alias,
      rules: [rule({ paths: ["Library/Caches/allowed"] })],
      dryRun: false,
    });

    assert.equal(result.results[0].status, "removed");
    assert.equal(await exists(target), false);
  } finally {
    await rm(realHome, { recursive: true, force: true });
    await rm(aliasParent, { recursive: true, force: true });
  }
});
