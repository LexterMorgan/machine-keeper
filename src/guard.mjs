import { readFileSync } from "node:fs";
import { realpath } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Shared policy, read from the repo root relative to this module rather than
 * the process cwd. The menu-bar app reads the same file from its bundle for
 * Explore, but Explore's stricter roots stay an app concern: cleanup rules
 * must remain free to target `~/Library/Caches`.
 *
 * `neverTouch` holds user work or credentials. Nothing a cleanup rule names
 * may be, contain, or live inside one of these locations.
 */
const POLICY_SCHEMA_VERSION = 1;
export const POLICY_FILE = fileURLToPath(new URL("../policy.json", import.meta.url));

function fail(file, message) {
  throw new Error(`invalid policy at ${file}: ${message}`);
}

function validatePath(value, file, where) {
  if (typeof value !== "string") {
    fail(file, `${where} must be a string`);
  }
  if (value.trim() === "") {
    fail(file, `${where} must be a non-empty relative path`);
  }
  if (value.trim() !== value) {
    fail(file, `${where} must not have leading or trailing whitespace`);
  }
  if (value.includes("\0")) {
    fail(file, `${where} must not contain a NUL byte`);
  }
  if (path.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value)) {
    fail(file, `${where} must be relative to home, not absolute: ${value}`);
  }
  if (value.startsWith("~")) {
    fail(file, `${where} must not use ~: ${value}`);
  }
  const segments = value.split("/");
  if (
    segments.some(
      (segment) => segment === "" || segment === "." || segment === ".."
    )
  ) {
    fail(file, `${where} must not contain "." or ".." or empty segments: ${value}`);
  }
  if (path.posix.normalize(value) !== value) {
    fail(file, `${where} must be a normalized slash-separated path: ${value}`);
  }
  return value;
}

function validatePathList(payload, key, file, { allowEmpty = false } = {}) {
  const list = payload[key];
  if (!Array.isArray(list)) {
    fail(file, `${key} must be an array`);
  }
  if (!allowEmpty && list.length === 0) {
    fail(file, `${key} must be a non-empty array`);
  }
  const seen = new Set();
  return list.map((value, index) => {
    const where = `${key}[${index}]`;
    const checked = validatePath(value, file, where);
    // Checks are case-insensitive, so "Documents" and "documents" would be
    // two entries doing the same job; reject the ambiguity.
    const keyName = checked.toLowerCase();
    if (seen.has(keyName)) {
      fail(file, `duplicate path in ${key}: ${value}`);
    }
    seen.add(keyName);
    return checked;
  });
}

/**
 * Validate a parsed policy payload without touching the filesystem. Pure so
 * tests and future consumers can check a policy file directly.
 */
export function validatePolicy(payload, { file = POLICY_FILE } = {}) {
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    fail(file, "root must be an object");
  }
  if (payload.schemaVersion !== POLICY_SCHEMA_VERSION) {
    fail(file, `schemaVersion must be ${POLICY_SCHEMA_VERSION}`);
  }
  const neverTouch = validatePathList(payload, "neverTouch", file);
  const exploreProtectedRoots = validatePathList(
    payload,
    "exploreProtectedRoots",
    file,
    { allowEmpty: true }
  );
  return Object.freeze({
    schemaVersion: POLICY_SCHEMA_VERSION,
    neverTouch: Object.freeze(neverTouch),
    exploreProtectedRoots: Object.freeze(exploreProtectedRoots),
  });
}

/**
 * Load the shared policy from disk. `file` is injectable for tests; runtime
 * callers use the module-relative path, never an environment variable or cwd.
 */
export function loadPolicy({ file = POLICY_FILE } = {}) {
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch (error) {
    throw new Error(`could not read policy at ${file}: ${error.message}`);
  }
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (error) {
    throw new Error(`invalid policy at ${file}: not valid JSON (${error.message})`);
  }
  return validatePolicy(payload, { file });
}

/** Immutable, validated runtime policy shared with the app. */
export const POLICY = loadPolicy();

const NEVER_TOUCH = POLICY.neverTouch;

export function relativeToHome(home, absolutePath) {
  return path
    .relative(path.resolve(home), path.resolve(absolutePath))
    .split(path.sep)
    .join("/");
}

function protectedKey(relativePath) {
  return relativePath.replace(/^\/+/, "").toLowerCase();
}

export function isProtectedRelative(relativePath) {
  const rel = protectedKey(relativePath);
  return NEVER_TOUCH.some((never) => {
    const key = never.toLowerCase();
    return rel === key || rel.startsWith(`${key}/`);
  });
}

/**
 * Whether a target is an ancestor of a protected location. Deleting
 * `~/Library` would remove `~/Library/Containers`, even though the target
 * itself is not inside the protected list.
 */
export function containsProtectedRelative(relativePath) {
  const rel = protectedKey(relativePath);
  if (rel === "") {
    return true;
  }
  return NEVER_TOUCH.some((never) => {
    const key = never.toLowerCase();
    return key === rel || key.startsWith(`${rel}/`);
  });
}

/**
 * Filesystem-aware final check before a destructive operation. Realpath
 * resolves symlinked parents and the home itself, then the target must still
 * be inside home and must not be, or contain, a protected location.
 *
 * This closes the gap between registry validation (string-only) and deletion.
 * It is deliberately conservative: an unverifiable target is refused.
 */
export async function assertDeletable(
  home,
  absolutePath,
  { fileSystem = { realpath } } = {}
) {
  const homeReal = await fileSystem.realpath(path.resolve(home));
  const targetReal = await fileSystem.realpath(path.resolve(absolutePath));
  const relative = path.relative(homeReal, targetReal);

  if (relative === "") {
    throw new Error("refusing to delete the home directory itself");
  }
  if (
    relative === ".." ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    throw new Error(`deletion target escapes home after resolving symlinks: ${absolutePath}`);
  }

  const rel = relative.split(path.sep).join("/");
  if (isProtectedRelative(rel)) {
    throw new Error(`refusing protected location: ${rel}`);
  }
  if (containsProtectedRelative(rel)) {
    throw new Error(`refusing target that contains a protected location: ${rel}`);
  }
  return targetReal;
}

/**
 * Turn a rule's home-relative path into an absolute path, refusing anything
 * that escapes home, equals home, or points into a user-data location.
 */
export function resolveRulePath(home, relativePath) {
  if (typeof relativePath !== "string" || relativePath.trim() === "") {
    throw new Error("rule path must be a non-empty string");
  }
  if (relativePath.startsWith("/") || relativePath.startsWith("~")) {
    throw new Error(`rule path must be relative to home: ${relativePath}`);
  }
  const normalized = path.normalize(relativePath);
  if (normalized === "." || normalized.startsWith("..")) {
    throw new Error(`rule path escapes home: ${relativePath}`);
  }

  const homeAbs = path.resolve(home);
  const absolute = path.resolve(homeAbs, normalized);
  if (absolute === homeAbs) {
    throw new Error("rule path must not be the home directory itself");
  }
  if (!absolute.startsWith(homeAbs + path.sep)) {
    throw new Error(`rule path escapes home: ${relativePath}`);
  }

  const rel = relativeToHome(homeAbs, absolute);
  if (isProtectedRelative(rel)) {
    throw new Error(`refusing protected location: ${rel}`);
  }
  return absolute;
}
