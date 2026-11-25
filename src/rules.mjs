import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { resolveRulePath } from "./guard.mjs";

export const SCHEMA_VERSION = 1;
export const RULE_KINDS = new Set(["delete", "command", "installers"]);
export const RISKS = new Set(["safe", "rebuild", "user-files"]);
const ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

const HERE = path.dirname(fileURLToPath(import.meta.url));

function fail(message) {
  throw new Error(`invalid rules: ${message}`);
}

/**
 * Validate a rule registry. Pure so contributors and tests can check a rule
 * set without touching the filesystem.
 */
export function validateRules(payload) {
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    fail("root must be an object");
  }
  if (payload.schemaVersion !== SCHEMA_VERSION) {
    fail(`schemaVersion must be ${SCHEMA_VERSION}`);
  }
  if (!Array.isArray(payload.rules) || payload.rules.length === 0) {
    fail("rules must be a non-empty array");
  }

  const seen = new Set();
  const rules = payload.rules.map((rule, index) => {
    const where = `rules[${index}]`;
    if (rule === null || typeof rule !== "object" || Array.isArray(rule)) {
      fail(`${where} must be an object`);
    }
    if (typeof rule.id !== "string" || !ID_PATTERN.test(rule.id)) {
      fail(`${where}.id must be kebab-case`);
    }
    if (seen.has(rule.id)) {
      fail(`duplicate rule id: ${rule.id}`);
    }
    seen.add(rule.id);

    if (typeof rule.title !== "string" || rule.title.trim() === "") {
      fail(`rule ${rule.id}: title is required`);
    }
    if (!RULE_KINDS.has(rule.kind)) {
      fail(`rule ${rule.id}: kind must be one of ${[...RULE_KINDS].join(", ")}`);
    }
    if (!RISKS.has(rule.risk)) {
      fail(`rule ${rule.id}: risk must be one of ${[...RISKS].join(", ")}`);
    }
    if (rule.risk === "user-files" && rule.optIn !== true) {
      fail(`rule ${rule.id}: risk "user-files" requires optIn: true`);
    }
    if (!Array.isArray(rule.paths) || rule.paths.length === 0) {
      fail(`rule ${rule.id}: paths must be a non-empty array`);
    }
    for (const rulePath of rule.paths) {
      if (typeof rulePath !== "string") {
        fail(`rule ${rule.id}: every path must be a string`);
      }
      try {
        resolveRulePath("/tmp/home", rulePath);
      } catch (error) {
        fail(`rule ${rule.id}: ${error.message}`);
      }
    }

    if (rule.kind === "command") {
      if (
        !Array.isArray(rule.command) ||
        rule.command.length === 0 ||
        rule.command.some((part) => typeof part !== "string" || part === "")
      ) {
        fail(`rule ${rule.id}: command must be a non-empty string array`);
      }
    }
    if (rule.kind === "installers") {
      if (
        !Array.isArray(rule.extensions) ||
        rule.extensions.length === 0 ||
        rule.extensions.some((ext) => !/^\.[a-z0-9]+$/i.test(ext))
      ) {
        fail(`rule ${rule.id}: extensions must look like [".dmg"]`);
      }
      if (!Number.isInteger(rule.days) || rule.days < 0) {
        fail(`rule ${rule.id}: days must be a non-negative integer`);
      }
    }
    if (rule.app !== undefined && typeof rule.app !== "string") {
      fail(`rule ${rule.id}: app must be a string`);
    }
    if (rule.optIn !== undefined && typeof rule.optIn !== "boolean") {
      fail(`rule ${rule.id}: optIn must be a boolean`);
    }
    if (rule.reclaim !== undefined && typeof rule.reclaim !== "string") {
      fail(`rule ${rule.id}: reclaim must be a string`);
    }

    return {
      ...rule,
      optIn: rule.optIn === true,
    };
  });

  return { schemaVersion: SCHEMA_VERSION, rules };
}

export function loadRules({ file } = {}) {
  const rulesFile =
    file ?? process.env.MK_RULES ?? path.join(HERE, "..", "rules.default.json");
  let raw;
  try {
    raw = readFileSync(rulesFile, "utf8");
  } catch (error) {
    throw new Error(`could not read rules at ${rulesFile}: ${error.message}`);
  }
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (error) {
    throw new Error(`rules at ${rulesFile} are not valid JSON: ${error.message}`);
  }
  return { ...validateRules(payload), file: rulesFile };
}

/** Filter by --only and drop opt-in rules unless explicitly included. */
export function selectRules(rules, { only = [], includeOptIn = false } = {}) {
  const known = new Set(rules.map((rule) => rule.id));
  const unknown = only.filter((id) => !known.has(id));
  if (unknown.length > 0) {
    throw new Error(`unknown rule id(s): ${unknown.join(", ")}`);
  }
  return rules.filter((rule) => {
    if (only.length > 0 && !only.includes(rule.id)) {
      return false;
    }
    if (rule.optIn && !includeOptIn) {
      return false;
    }
    return true;
  });
}
