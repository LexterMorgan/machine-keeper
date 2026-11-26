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
