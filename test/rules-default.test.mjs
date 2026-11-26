import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { resolveRulePath } from "../src/guard.mjs";
import { loadRules, selectRules } from "../src/rules.mjs";

const DEFAULT_RULES = fileURLToPath(new URL("../rules.default.json", import.meta.url));

test("default rules are portable, validated, and safe by default", () => {
  const { rules } = loadRules({ file: DEFAULT_RULES });
  assert.ok(rules.length >= 25, "default registry should cover common developer caches");

  for (const rule of rules) {
    for (const rulePath of rule.paths) {
      assert.equal(path.isAbsolute(rulePath), false, `${rule.id} path must be home-relative`);
      assert.equal(rulePath.startsWith("~"), false, `${rule.id} path must not use ~`);
      assert.doesNotThrow(
        () => resolveRulePath("/Users/example", rulePath),
        `${rule.id} path must pass the guard: ${rulePath}`
      );
    }
    if (rule.risk === "user-files") {
      assert.equal(rule.optIn, true, `${rule.id} is user-files and must be opt-in`);
    }
  }
});

test("common non-App-specific toolchains are in the defaults", () => {
  const { rules } = loadRules({ file: DEFAULT_RULES });
  const ids = new Set(rules.map((rule) => rule.id));
  for (const id of [
    "yarn-cache",
    "bun-cache",
    "deno-cache",
    "go-cache",
    "cargo-cache",
    "gradle-cache",
    "maven-cache",
    "swiftpm-cache",
    "cocoapods-cache",
    "puppeteer-browsers",
    "cypress-cache",
    "electron-cache",
    "vscode-cache",
    "cursor-cache",
  ]) {
    assert.ok(ids.has(id), `missing general rule: ${id}`);
  }

  assert.deepEqual(
    selectRules(rules, { only: ["go-cache"] }).map((rule) => rule.id),
    ["go-cache"]
  );
});

test("shipped user-files rules are opt-in and app-guarded where needed", () => {
  const { rules } = loadRules({ file: DEFAULT_RULES });
  const maven = rules.find((rule) => rule.id === "maven-cache");
  const cursorResidue = rules.find((rule) => rule.id === "cursor-residue");

  assert.equal(maven.risk, "user-files");
  assert.equal(maven.optIn, true);
  assert.match(maven.reclaim, /unpublished|locally installed/);
  assert.equal(cursorResidue.optIn, true);
  assert.equal(cursorResidue.app, "Cursor");

  assert.equal(selectRules(rules, { only: ["maven-cache"] }).length, 0);
  assert.equal(
    selectRules(rules, { only: ["maven-cache"], includeOptIn: true }).length,
    1
  );
});

test("command rules are limited to commands reviewed as target-scoped", () => {
  const { rules } = loadRules({ file: DEFAULT_RULES });
  const commands = rules
    .filter((rule) => rule.kind === "command")
    .map((rule) => rule.id)
    .sort();

  assert.deepEqual(commands, ["go-cache", "npm-cache", "pip-cache", "pnpm-store", "uv-cache"]);
  const brew = rules.find((rule) => rule.id === "brew-cleanup");
  assert.equal(brew.kind, "delete");
  assert.equal(brew.command, undefined);
});
