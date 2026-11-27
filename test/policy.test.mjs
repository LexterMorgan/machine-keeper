import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { clean } from "../src/clean.mjs";
import { buildFullReport, main } from "../src/cli.mjs";
import {
  POLICY,
  POLICY_FILE,
  containsProtectedRelative,
  isProtectedRelative,
  loadPolicy,
  resolveRulePath,
  validatePolicy,
} from "../src/guard.mjs";
import { loadRules, selectRules } from "../src/rules.mjs";
import { installSchedule, plistPath } from "../src/schedule.mjs";

const EXPECTED_NEVER_TOUCH = [
  "Documents",
  "Desktop",
  "Pictures",
  "Music",
  "Movies",
  "Projects",
  "Sources",
  "Library/Containers",
  "Library/Mobile Documents",
  "Library/Preferences",
  "Library/Keychains",
  "Library/Mail",
  "Library/Messages",
  ".ssh",
  ".aws",
  ".gnupg",
  ".config",
  ".password-store",
];

const EXPECTED_EXPLORE_ROOTS = ["Library"];
const SHIPPED = loadRules();

async function withTempDir(prefix, fn) {
  const directory = await mkdtemp(path.join(os.tmpdir(), prefix));
  try {
    return await fn(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function exists(target) {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
}

const VALID_POLICY = {
  schemaVersion: 1,
  neverTouch: ["Documents"],
  exploreProtectedRoots: ["Library"],
};

test("the shared policy exactly matches the agreed neverTouch list", () => {
  assert.equal(POLICY.schemaVersion, 1);
  assert.deepEqual([...POLICY.neverTouch], EXPECTED_NEVER_TOUCH);
  assert.deepEqual([...POLICY.exploreProtectedRoots], EXPECTED_EXPLORE_ROOTS);
  assert.equal(POLICY_FILE, fileURLToPath(new URL("../policy.json", import.meta.url)));

  // The guard must not be able to drift from the app's copy at runtime.
  assert.ok(Object.isFrozen(POLICY));
  assert.ok(Object.isFrozen(POLICY.neverTouch));
  assert.ok(Object.isFrozen(POLICY.exploreProtectedRoots));
  assert.throws(() => POLICY.neverTouch.push("Library"), TypeError);
});

test("policy loading is relative to src/guard.mjs, not the process cwd", async () => {
  await withTempDir("mk-policy-cwd-", async (cwd) => {
    // A decoy in the cwd must never be read: only the module-relative file is.
    await writeFile(
      path.join(cwd, "policy.json"),
      JSON.stringify({
        schemaVersion: 1,
        neverTouch: ["DecoyCwdEntry"],
        exploreProtectedRoots: [],
      })
    );

    const moduleUrl = new URL("../src/guard.mjs", import.meta.url).href;
    const script =
      `import(${JSON.stringify(moduleUrl)}).then((module) => {` +
      `process.stdout.write(JSON.stringify(module.POLICY.neverTouch));` +
      `});`;
    const stdout = execFileSync(
      process.execPath,
      ["--input-type=module", "--eval", script],
      { cwd, encoding: "utf8" }
    );

    assert.deepEqual(JSON.parse(stdout), EXPECTED_NEVER_TOUCH);
  });
});

test("policy validation rejects malformed payloads and missing files", async () => {
  const invalid = [
    [null, /root must be an object/],
    [[], /root must be an object/],
    [{ ...VALID_POLICY, schemaVersion: 2 }, /schemaVersion must be 1/],
    [{ ...VALID_POLICY, schemaVersion: "1" }, /schemaVersion must be 1/],
    [{ ...VALID_POLICY, neverTouch: "Documents" }, /neverTouch must be an array/],
    [{ ...VALID_POLICY, neverTouch: [] }, /neverTouch must be a non-empty array/],
    [
      { schemaVersion: 1, exploreProtectedRoots: ["Library"] },
      /neverTouch must be an array/,
    ],
    [{ ...VALID_POLICY, neverTouch: [42] }, /neverTouch\[0\] must be a string/],
    [{ ...VALID_POLICY, neverTouch: [""] }, /neverTouch\[0\].*non-empty/],
    [
      { ...VALID_POLICY, neverTouch: [" Documents"] },
      /neverTouch\[0\].*whitespace/,
    ],
    [
      { ...VALID_POLICY, neverTouch: ["/private/tmp"] },
      /neverTouch\[0\].*relative to home/,
    ],
    [{ ...VALID_POLICY, neverTouch: ["../escape"] }, /neverTouch\[0\].*\.\./],
    [{ ...VALID_POLICY, neverTouch: ["a/../b"] }, /neverTouch\[0\].*\.\./],
    [{ ...VALID_POLICY, neverTouch: ["~/secrets"] }, /neverTouch\[0\].*~/],
    [
      { ...VALID_POLICY, neverTouch: ["Documents", "documents"] },
      /duplicate path in neverTouch/,
    ],
    [
      { ...VALID_POLICY, exploreProtectedRoots: "Library" },
      /exploreProtectedRoots must be an array/,
    ],
    [
      { ...VALID_POLICY, exploreProtectedRoots: ["Library", "library"] },
      /duplicate path in exploreProtectedRoots/,
    ],
    [
      { schemaVersion: 1, neverTouch: ["Documents"] },
      /exploreProtectedRoots must be an array/,
    ],
    [
      { ...VALID_POLICY, exploreProtectedRoots: ["/Library"] },
      /exploreProtectedRoots\[0\].*relative to home/,
    ],
  ];

  for (const [payload, pattern] of invalid) {
    assert.throws(() => validatePolicy(payload, { file: "policy.json" }), pattern);
  }

  await withTempDir("mk-policy-bad-", async (directory) => {
    const missing = path.join(directory, "missing.json");
    assert.throws(
      () => loadPolicy({ file: missing }),
      /could not read policy at .*missing\.json/
    );

    const malformed = path.join(directory, "malformed.json");
    await writeFile(malformed, "{ definitely not json");
    assert.throws(() => loadPolicy({ file: malformed }), /not valid JSON/);

    await writeFile(
      malformed,
      JSON.stringify({ ...VALID_POLICY, schemaVersion: 3 })
    );
    assert.throws(
      () => loadPolicy({ file: malformed }),
      /schemaVersion must be 1/
    );
  });
});

test("a valid minimal policy is accepted, normalized, and frozen", () => {
  const policy = validatePolicy(VALID_POLICY, { file: "policy.json" });

  assert.deepEqual({ ...policy }, VALID_POLICY);
  assert.ok(Object.isFrozen(policy));
  assert.ok(Object.isFrozen(policy.neverTouch));
  assert.ok(Object.isFrozen(policy.exploreProtectedRoots));

  const emptyExplore = validatePolicy(
    { ...VALID_POLICY, exploreProtectedRoots: [] },
    { file: "policy.json" }
  );
  assert.deepEqual([...emptyExplore.exploreProtectedRoots], []);
});

test("protected checks stay case-insensitive and Library remains app-only", () => {
  assert.equal(isProtectedRelative("Documents/taxes"), true);
  assert.equal(isProtectedRelative("documents/taxes"), true);
  assert.equal(isProtectedRelative("library/containers/app"), true);
  assert.equal(isProtectedRelative("Library/Application Support/Code"), false);
  assert.equal(isProtectedRelative(".SSH/id_ed25519"), true);
  assert.equal(isProtectedRelative("Projects/keep"), true);

  // Explore protects all of ~/Library in the app. Cleanup neverTouch must not
  // adopt that root or every Library-cache rule would break.
  assert.equal(isProtectedRelative("Library"), false);
  assert.equal(isProtectedRelative("Library/Caches/Google"), false);
  assert.equal(containsProtectedRelative("Library"), true);
  assert.equal(containsProtectedRelative("library"), true);
  assert.equal(containsProtectedRelative("Library/Caches"), false);
  assert.equal(containsProtectedRelative(""), true);
  assert.equal(POLICY.neverTouch.includes("Library"), false);
  assert.deepEqual([...POLICY.exploreProtectedRoots], ["Library"]);

  assert.doesNotThrow(() =>
    resolveRulePath("/Users/example", "Library/Caches/Google")
  );
});

test("every neverTouch entry is home-relative and refused as protected", async () => {
  await withTempDir("mk-policy-home-", async (home) => {
    for (const entry of POLICY.neverTouch) {
      assert.equal(path.isAbsolute(entry), false, `${entry} must be relative`);
      assert.equal(entry.startsWith("~"), false, `${entry} must not use ~`);
      assert.equal(entry.split("/").includes(".."), false, `${entry} must not traverse`);

      // resolveRulePath parses the home-relative shape, then refuses because
      // these entries are exactly the protected locations. "relative to home"
      // or "escapes home" here would mean the policy entry itself is malformed.
      assert.throws(() => resolveRulePath(home, entry), /protected location/, entry);
      assert.throws(
        () => resolveRulePath(home, `${entry}/nested`),
        /protected location/,
        entry
      );
    }
  });
});

test("the shipped cleanup rules still resolve, including Library caches", () => {
  assert.ok(SHIPPED.rules.length >= 25);

  for (const rule of SHIPPED.rules) {
    for (const rulePath of rule.paths) {
      assert.doesNotThrow(
        () => resolveRulePath("/Users/example", rulePath),
        `${rule.id}: ${rulePath}`
      );
    }
  }

  const brew = SHIPPED.rules.find((rule) => rule.id === "brew-cleanup");
  assert.ok(brew.paths.includes("Library/Caches/Homebrew"));
  assert.doesNotThrow(() =>
    resolveRulePath("/Users/example", "Library/Caches/Google/Chrome")
  );
});

test("an off-registry Downloads file never becomes a rule, clean result, or report row", async () => {
  await withTempDir("mk-policy-downloads-", async (home) => {
    const folder = path.join(home, "Downloads", "off-registry-project");
    await mkdir(folder, { recursive: true });
    const nested = path.join(folder, "keep-me.txt");
    await writeFile(nested, Buffer.alloc(512));
    const topLevel = path.join(home, "Downloads", "off-registry-notes.txt");
    await writeFile(topLevel, Buffer.alloc(64));

    for (const rule of SHIPPED.rules) {
      for (const rulePath of rule.paths) {
        assert.equal(
          rulePath.includes("off-registry"),
          false,
          `${rule.id} must not name arbitrary Downloads content`
        );
      }
    }

    // Nothing in the default registry can remove an arbitrary Downloads file.
    // A spy proves remove() is never reached even though clean is not a dry run.
    const removeCalls = [];
    const defaultRules = selectRules(SHIPPED.rules, {});
    const cleanResult = await clean({
      home,
      rules: defaultRules,
      dryRun: false,
      appRunning: async () => false,
      remove: async (...args) => {
        removeCalls.push(args);
        throw new Error("default cleanup must not remove arbitrary content");
      },
    });

    assert.deepEqual(removeCalls, []);
    assert.deepEqual(
      cleanResult.results.map((row) => row.id),
      defaultRules.map((rule) => rule.id)
    );
    assert.ok(cleanResult.results.every((row) => row.status === "missing"));
    assert.equal(cleanResult.freedBytes, 0);
    assert.equal(await exists(nested), true);
    assert.equal(await exists(topLevel), true);

    // clean() accepts validated rule objects only. There is no Node-side
    // Explore entry point that could promote a filesystem path into the app's
    // clean-safe set, so an empty rule list reaches no path at all.
    const empty = await clean({
      home,
      rules: [],
      dryRun: false,
      remove: async () => {
        throw new Error("no rules must mean no removal");
      },
    });
    assert.deepEqual(empty.results, []);

    const report = await buildFullReport({
      home,
      rules: selectRules(SHIPPED.rules, { includeOptIn: true }),
      now: () => new Date("2026-11-27T00:00:00.000Z"),
      system: {
        diskInfo: async () => null,
        memoryInfo: async () => null,
      },
      appRunning: async () => false,
      runCmd: async () => ({ ok: false, stdout: "", stderr: "" }),
      audit: async () => ({
        userAgents: [],
        systemAgents: [],
        systemDaemons: [],
        loginItems: [],
        brewServices: null,
      }),
    });

    assert.deepEqual(
      report.rows.map((row) => row.id),
      SHIPPED.rules.map((rule) => rule.id)
    );
    assert.deepEqual(
      report.optInRows.map((row) => row.id),
      SHIPPED.rules.filter((rule) => rule.optIn).map((rule) => rule.id)
    );
    for (const row of [...report.rows, ...report.optInRows]) {
      assert.equal("path" in row, false, `${row.id} exposes no arbitrary path`);
    }

    const serialized = JSON.stringify(report);
    assert.equal(serialized.includes("off-registry-project"), false);
    assert.equal(serialized.includes("off-registry-notes.txt"), false);
    assert.equal(await exists(nested), true);
    assert.equal(await exists(topLevel), true);
  });
});

test("the scheduled task only writes a report job and deletes nothing", async () => {
  await withTempDir("mk-policy-schedule-", async (home) => {
    const keep = path.join(home, "Downloads", "off-registry-project", "keep-me.txt");
    await mkdir(path.dirname(keep), { recursive: true });
    await writeFile(keep, Buffer.alloc(256));

    const calls = [];
    const result = await installSchedule({
      home,
      scriptPath: "/opt/machine-keeper/bin/mk.mjs",
      nodePath: "/usr/local/bin/node",
      runCmd: async (command, args) => {
        calls.push([command, ...(args ?? [])]);
        return { ok: true, stdout: "", stderr: "" };
      },
    });

    assert.equal(result.loaded, true);
    assert.deepEqual(calls.map(([command]) => command), ["launchctl"]);
    assert.deepEqual(calls[0].slice(0, 2), ["launchctl", "bootstrap"]);

    const plist = await readFile(plistPath(home), "utf8");
    assert.match(plist, /<string>report<\/string>/);
    assert.match(plist, /<string>--json<\/string>/);
    assert.doesNotMatch(plist, /<string>clean<\/string>/);
    assert.doesNotMatch(plist, /--yes/);
    assert.equal(await exists(keep), true);
  });
});

test("the CLI loads the shared policy and refuses protected rule paths", async () => {
  await withTempDir("mk-policy-cli-", async (home) => {
    const output = [];
    const code = await main(["rules", "--json"], {
      home,
      platform: "darwin",
      out: (line) => output.push(line),
    });
    assert.equal(code, 0);

    const rules = JSON.parse(output.join("\n"));
    assert.ok(rules.length >= 25);
    assert.ok(rules.some((rule) => rule.id === "brew-cleanup"));
    assert.ok(rules.some((rule) => rule.paths.includes("Library/Caches/Homebrew")));

    const rulesFile = path.join(home, "blocked-rules.json");
    await writeFile(
      rulesFile,
      JSON.stringify({
        schemaVersion: 1,
        rules: [
          {
            id: "blocked",
            title: "blocked",
            kind: "delete",
            paths: ["Library/Containers"],
            risk: "rebuild",
          },
        ],
      })
    );

    await assert.rejects(
      main(["clean", "--yes"], {
        home,
        rulesFile,
        platform: "darwin",
        out: () => {},
      }),
      /protected location/
    );
  });
});

test("the shared policy is packaged with the Node CLI", async () => {
  const pkg = JSON.parse(
    await readFile(new URL("../package.json", import.meta.url), "utf8")
  );
  assert.ok(
    pkg.files.includes("policy.json"),
    "package.json files must include policy.json so the guard can load it"
  );
  assert.equal(await exists(POLICY_FILE), true);
});
