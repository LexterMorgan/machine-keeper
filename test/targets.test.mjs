import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { clean } from "../src/clean.mjs";
import { buildReport } from "../src/report.mjs";
import { isAppRunning } from "../src/targets.mjs";

test("isAppRunning reports a match", async () => {
  const calls = [];
  const running = await isAppRunning("Spotify", {
    runCmd: async (command, args) => {
      calls.push([command, ...args].join(" "));
      return { ok: true, stdout: "4242\n", stderr: "" };
    },
  });
  assert.equal(running, true);
  assert.deepEqual(calls, ["pgrep -f Spotify.app/Contents/MacOS"]);
});

test("isAppRunning reports no match", async () => {
  const running = await isAppRunning("Spotify", {
    runCmd: async () => ({ ok: true, stdout: "", stderr: "" }),
  });
  assert.equal(running, false);
});

test("isAppRunning treats pgrep exit 1 as not running", async () => {
  const running = await isAppRunning("Spotify", {
    runCmd: async () => ({ ok: false, code: 1, stdout: "", stderr: "" }),
  });
  assert.equal(running, false);
});

test("isAppRunning fails closed when pgrep cannot answer", async () => {
  for (const code of [2, 127, null, "ENOENT"]) {
    const running = await isAppRunning("Spotify", {
      runCmd: async () => ({ ok: false, code, stdout: "", stderr: "pgrep failed" }),
    });
    assert.equal(running, true, `expected unknown code ${String(code)} to fail closed`);
  }
});

test("clean skips an app rule when the running check is unknown", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-targets-"));
  try {
    const target = path.join(home, "Library", "Caches", "test-cache");
    await mkdir(target, { recursive: true });
    await writeFile(path.join(target, "blob.bin"), Buffer.alloc(4096));

    const result = await clean({
      home,
      rules: [
        {
          id: "test-cache",
          title: "test cache",
          kind: "delete",
          paths: ["Library/Caches/test-cache"],
          risk: "rebuild",
          app: "Spotify",
        },
      ],
      dryRun: false,
      runCmd: async (command, args) => {
        if (command === "du") {
          return { ok: true, code: 0, stdout: `4\t${args[1]}\n`, stderr: "" };
        }
        return { ok: false, code: 2, stdout: "", stderr: "pgrep failed" };
      },
    });

    assert.equal(result.results[0].status, "skipped-app-running");
    await stat(path.join(target, "blob.bin"));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("report marks a rule blocked when the running check is unknown", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-targets-"));
  try {
    const target = path.join(home, "Library", "Caches", "test-cache");
    await mkdir(target, { recursive: true });
    await writeFile(path.join(target, "blob.bin"), Buffer.alloc(4096));

    const report = await buildReport({
      home,
      rules: [
        {
          id: "test-cache",
          title: "test cache",
          kind: "delete",
          paths: ["Library/Caches/test-cache"],
          risk: "rebuild",
          app: "Spotify",
        },
      ],
      system: {
        diskInfo: async () => null,
        memoryInfo: async () => null,
      },
      runCmd: async (command, args) => {
        if (command === "du") {
          return { ok: true, code: 0, stdout: `4\t${args[1]}\n`, stderr: "" };
        }
        return { ok: false, code: 2, stdout: "", stderr: "pgrep failed" };
      },
      now: () => new Date("2026-11-25T00:00:00.000Z"),
    });

    assert.equal(report.rows[0].appRunning, true);
    assert.equal(report.blockedBytes, report.rows[0].bytes);
    assert.equal(report.sweepableBytes, 0);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
