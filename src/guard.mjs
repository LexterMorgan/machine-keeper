import { realpath } from "node:fs/promises";
import path from "node:path";

/**
 * Locations Machine Keeper refuses to delete inside, even when a rule names
 * them. These hold user work or credentials, never build caches.
 */
const NEVER_TOUCH = [
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
