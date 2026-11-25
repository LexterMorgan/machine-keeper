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

export function isProtectedRelative(relativePath) {
  const rel = relativePath.replace(/^\/+/, "");
  return NEVER_TOUCH.some(
    (never) => rel === never || rel.startsWith(`${never}/`)
  );
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
