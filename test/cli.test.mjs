import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { HELP, VERSION, main, parseArgs } from "../src/cli.mjs";

test("parseArgs defaults to report", () => {
  const options = parseArgs([]);
  assert.equal(options.command, "report");
  assert.equal(options.json, false);
  assert.equal(options.yes, false);
});

test("parseArgs reads flags and commands", () => {
  const options = parseArgs(["clean", "--yes", "--only", "npm-cache, uv-cache", "--json"]);
  assert.equal(options.command, "clean");
  assert.equal(options.yes, true);
  assert.equal(options.json, true);
  assert.deepEqual(options.only, ["npm-cache", "uv-cache"]);
});

test("parseArgs supports --only=a,b", () => {
  assert.deepEqual(parseArgs(["--only=a,b"]).only, ["a", "b"]);
});

test("parseArgs rejects unknown input", () => {
  assert.throws(() => parseArgs(["--nope"]), /unknown flag/);
  assert.throws(() => parseArgs(["frobnicate"]), /unknown command/);
  assert.throws(() => parseArgs(["report", "extra"]), /unexpected argument/);
  assert.throws(() => parseArgs(["--only"]), /--only needs/);
});

test("help prints usage and exits 0", async () => {
  const out = [];
  const code = await main(["--help"], { platform: "darwin", out: (line) => out.push(line) });
  assert.equal(code, 0);
  assert.ok(out.join("\n").includes("mk clean --yes"));
  assert.ok(HELP.includes(VERSION));
});

test("non-macOS platforms get a clear message", async () => {
  const out = [];
  const code = await main(["report"], { platform: "linux", out: (line) => out.push(line) });
  assert.equal(code, 2);
  assert.match(out.join("\n"), /macOS only/);
});

test("clean --json end to end against a temporary home", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-cli-"));
  try {
    const cache = path.join(home, "Library", "Caches", "test-cache");
    await mkdir(cache, { recursive: true });
    await writeFile(path.join(cache, "blob.bin"), Buffer.alloc(120_000));

    const rulesFile = path.join(home, "rules.json");
    await writeFile(
      rulesFile,
      JSON.stringify({
        schemaVersion: 1,
        rules: [
          {
            id: "test-cache",
            title: "test cache",
            kind: "delete",
            paths: ["Library/Caches/test-cache"],
            risk: "rebuild",
          },
        ],
      })
    );

    const output = [];
    const code = await main(["clean", "--yes", "--json"], {
      home,
      rulesFile,
      platform: "darwin",
      out: (line) => output.push(line),
    });

    assert.equal(code, 0);
    const result = JSON.parse(output.join("\n"));
    assert.equal(result.dryRun, false);
    assert.equal(result.results[0].status, "removed");
    assert.ok(result.freedBytes > 0);
    await assert.rejects(stat(cache));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("clean without --yes is a dry run", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-cli-"));
  try {
    const cache = path.join(home, "Library", "Caches", "test-cache");
    await mkdir(cache, { recursive: true });
    await writeFile(path.join(cache, "blob.bin"), Buffer.alloc(50_000));

    const rulesFile = path.join(home, "rules.json");
    await writeFile(
      rulesFile,
      JSON.stringify({
        schemaVersion: 1,
        rules: [
          {
            id: "test-cache",
            title: "test cache",
            kind: "delete",
            paths: ["Library/Caches/test-cache"],
            risk: "rebuild",
          },
        ],
      })
    );

    const output = [];
    await main(["clean", "--json"], {
      home,
      rulesFile,
      platform: "darwin",
      out: (line) => output.push(line),
    });

    const result = JSON.parse(output.join("\n"));
    assert.equal(result.dryRun, true);
    assert.equal(result.results[0].status, "would-remove");
    await stat(cache);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
