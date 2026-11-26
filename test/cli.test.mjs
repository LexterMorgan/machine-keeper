import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { HELP, VERSION, main, parseArgs } from "../src/cli.mjs";

async function exists(target) {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
}

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

test("parseArgs rejects empty --only occurrences in either syntax", () => {
  for (const argv of [
    ["--only="],
    ["--only=   "],
    ["--only=,,,"],
    ["--only", ""],
    ["--only", "   "],
    ["--only", ",,,"],
    ["--only", "npm-cache", "--only="],
  ]) {
    assert.throws(() => parseArgs(argv), /--only/);
  }
});

test("parseArgs accepts valid repeated --only occurrences", () => {
  assert.deepEqual(parseArgs(["--only", "npm-cache, uv-cache", "--only=pip-cache"]).only, [
    "npm-cache",
    "uv-cache",
    "pip-cache",
  ]);
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
test("clean with an empty --only filter fails before touching a disposable target", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-cli-"));
  try {
    const target = path.join(home, "Library", "Caches", "must-survive");
    await mkdir(target, { recursive: true });
    const sentinel = path.join(target, "sentinel.bin");
    await writeFile(sentinel, Buffer.alloc(64));

    await assert.rejects(
      main(["clean", "--yes", "--only="], {
        home,
        platform: "darwin",
        out: () => {},
      }),
      /--only=/
    );
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

async function writeCommandRules(home, script) {
  const rulesFile = path.join(home, "rules.json");
  await writeFile(
    rulesFile,
    JSON.stringify({
      schemaVersion: 1,
      rules: [
        {
          id: "test-command",
          title: "test command",
          kind: "command",
          paths: ["Library/Caches/test-command"],
          command: [script],
          risk: "rebuild",
        },
      ],
    })
  );
  return rulesFile;
}

test("clean --yes reaches the production command runner and removes a disposable cache", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-cli-"));
  try {
    const target = path.join(home, "Library", "Caches", "test-command");
    await mkdir(target, { recursive: true });
    await writeFile(path.join(target, "blob.bin"), Buffer.alloc(50_000));
    const script = path.join(home, "fake-clean.sh");
    const marker = path.join(home, "command-ran");
    await writeFile(script, "#!/bin/sh\nprintf called > \"$(dirname \"$0\")/command-ran\"\n");
    await chmod(script, 0o755);
    const rulesFile = await writeCommandRules(home, script);

    const output = [];
    const code = await main(["clean", "--yes", "--json"], {
      home,
      rulesFile,
      platform: "darwin",
      out: (line) => output.push(line),
    });

    assert.equal(code, 0);
    assert.equal(JSON.parse(output.join("\n")).results[0].status, "removed");
    assert.equal(await exists(marker), true);
    assert.equal(await exists(target), false);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("clean --yes does not fall back to recursion when the command fails", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-cli-"));
  try {
    const sentinel = path.join(home, "Library", "Caches", "test-command", "sentinel.bin");
    await mkdir(path.dirname(sentinel), { recursive: true });
    await writeFile(sentinel, Buffer.alloc(50_000));
    const script = path.join(home, "fail-clean.sh");
    await writeFile(script, "#!/bin/sh\nexit 7\n");
    await chmod(script, 0o755);
    const rulesFile = await writeCommandRules(home, script);

    const output = [];
    const code = await main(["clean", "--yes", "--json"], {
      home,
      rulesFile,
      platform: "darwin",
      out: (line) => output.push(line),
    });

    assert.equal(code, 0);
    const result = JSON.parse(output.join("\n")).results[0];
    assert.equal(result.status, "error");
    assert.match(result.error, /cleanup command failed/);
    assert.equal(await exists(sentinel), true);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
