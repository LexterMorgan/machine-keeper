import test from "node:test";
import assert from "node:assert/strict";
import { isProtectedRelative, resolveRulePath } from "../src/guard.mjs";
import { selectRules, validateRules } from "../src/rules.mjs";

const HOME = "/Users/tester";

test("resolveRulePath accepts caches and resolves under home", () => {
  assert.equal(
    resolveRulePath(HOME, "Library/Caches/ms-playwright"),
    "/Users/tester/Library/Caches/ms-playwright"
  );
});

test("resolveRulePath refuses escapes and absolute paths", () => {
  assert.throws(() => resolveRulePath(HOME, "../etc/passwd"), /escapes home/);
  assert.throws(() => resolveRulePath(HOME, "/tmp/x"), /relative to home/);
  assert.throws(() => resolveRulePath(HOME, "~/x"), /relative to home/);
  assert.throws(() => resolveRulePath(HOME, ""), /non-empty/);
  assert.throws(() => resolveRulePath(HOME, "."), /escapes home/);
});

test("resolveRulePath refuses user-data locations", () => {
  assert.throws(() => resolveRulePath(HOME, "Documents/taxes"), /protected/);
  assert.throws(() => resolveRulePath(HOME, "Library/Containers/app"), /protected/);
  assert.throws(() => resolveRulePath(HOME, ".ssh/id_ed25519"), /protected/);
  assert.equal(isProtectedRelative("Projects/foo"), true);
  assert.equal(isProtectedRelative("Library/Caches/Google"), false);
});

function rule(overrides = {}) {
  return {
    id: "npm-cache",
    title: "npm cache",
    kind: "delete",
    paths: [".npm/_cacache"],
    risk: "rebuild",
    ...overrides,
  };
}

test("validateRules accepts a minimal registry", () => {
  const { rules } = validateRules({ schemaVersion: 1, rules: [rule()] });
  assert.equal(rules.length, 1);
  assert.equal(rules[0].optIn, false);
});

test("validateRules rejects bad input with useful messages", () => {
  assert.throws(() => validateRules({ schemaVersion: 2, rules: [rule()] }), /schemaVersion/);
  assert.throws(() => validateRules({ schemaVersion: 1, rules: [] }), /non-empty/);
  assert.throws(
    () => validateRules({ schemaVersion: 1, rules: [rule(), rule()] }),
    /duplicate rule id/
  );
  assert.throws(
    () => validateRules({ schemaVersion: 1, rules: [rule({ kind: "rm-rf" })] }),
    /kind must be one of/
  );
  assert.throws(
    () => validateRules({ schemaVersion: 1, rules: [rule({ risk: "yolo" })] }),
    /risk must be one of/
  );
  assert.throws(
    () => validateRules({ schemaVersion: 1, rules: [rule({ paths: ["../outside"] })] }),
    /escapes home/
  );
  assert.throws(
    () =>
      validateRules({
        schemaVersion: 1,
        rules: [rule({ kind: "installers", paths: ["Downloads"], extensions: [".dmg"] })],
      }),
    /days must be/
  );
});

test("selectRules filters opt-in and --only", () => {
  const rules = [
    rule(),
    rule({ id: "steam", title: "Steam", paths: ["Library/Application Support/Steam"], optIn: true }),
    rule({ id: "uv", title: "uv", paths: [".cache/uv"] }),
  ];

  assert.deepEqual(
    selectRules(rules, {}).map((entry) => entry.id),
    ["npm-cache", "uv"]
  );
  assert.deepEqual(
    selectRules(rules, { includeOptIn: true }).map((entry) => entry.id),
    ["npm-cache", "steam", "uv"]
  );
  assert.deepEqual(
    selectRules(rules, { only: ["uv"] }).map((entry) => entry.id),
    ["uv"]
  );
  assert.throws(() => selectRules(rules, { only: ["nope"] }), /unknown rule id/);
});

test("validateRules requires optIn for user-files risk", () => {
  assert.throws(
    () => validateRules({ schemaVersion: 1, rules: [rule({ risk: "user-files" })] }),
    /requires optIn/
  );

  const { rules } = validateRules({
    schemaVersion: 1,
    rules: [rule({ id: "steam", risk: "user-files", optIn: true })],
  });
  assert.equal(rules[0].optIn, true);
});
