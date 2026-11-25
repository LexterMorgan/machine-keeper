const UNITS = ["B", "KB", "MB", "GB", "TB"];

/** Format a byte count the way `du -h` does (1024-based). */
export function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return "0 B";
  }
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const precision = value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(precision)} ${UNITS[unit]}`;
}

/** Parse the kilobyte column of `du -sk` output. */
export function parseDuKilobytes(stdout) {
  const first = String(stdout ?? "").trim().split("\n")[0] ?? "";
  const kilobytes = Number.parseInt(first.split(/\s+/)[0] ?? "", 10);
  return Number.isFinite(kilobytes) ? kilobytes * 1024 : 0;
}
