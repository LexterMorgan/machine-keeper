import { run as defaultRun } from "./exec.mjs";

export const DEFAULT_VOLUME = "/System/Volumes/Data";
export const DEFAULT_PAGE_SIZE = 16384;

const PRESSURE_LABELS = {
  1: "normal",
  2: "warning",
  4: "critical",
};

export function pressureLabel(level) {
  return PRESSURE_LABELS[level] ?? "unknown";
}

/** Parse `df -k <volume>`. Returns null when the output is not a df table. */
export function parseDf(stdout) {
  const lines = String(stdout ?? "").trim().split("\n");
  const row = lines[1];
  if (!row) {
    return null;
  }
  const columns = row.trim().split(/\s+/);
  const total = Number(columns[1]);
  const used = Number(columns[2]);
  const free = Number(columns[3]);
  if (![total, used, free].every(Number.isFinite)) {
    return null;
  }
  return {
    totalBytes: total * 1024,
    usedBytes: used * 1024,
    freeBytes: free * 1024,
    percent: columns[4] ?? "?",
  };
}

/** Parse `sysctl vm.swapusage`. */
export function parseSwap(stdout) {
  const text = String(stdout ?? "");
  const read = (name) => {
    const match = new RegExp(`${name} = ([0-9.]+)([MG])`).exec(text);
    if (!match) {
      return 0;
    }
    const value = Number(match[1]);
    const multiplier = match[2] === "G" ? 1024 ** 3 : 1024 ** 2;
    return Math.round(value * multiplier);
  };
  return {
    totalBytes: read("total"),
    usedBytes: read("used"),
    freeBytes: read("free"),
  };
}

/** Parse `vm_stat` into a page-count map. */
export function parseVmStat(stdout) {
  const pages = {};
  for (const line of String(stdout ?? "").split("\n")) {
    const match = /^(.+?):\s+([0-9]+)\.?\s*$/.exec(line);
    if (!match) {
      continue;
    }
    pages[match[1].trim()] = Number(match[2]);
  }
  return pages;
}

function pageBytes(pages, key, pageSize) {
  return (pages[key] ?? 0) * pageSize;
}

export async function diskInfo({ runCmd = defaultRun, volume = DEFAULT_VOLUME } = {}) {
  const result = await runCmd("df", ["-k", volume]);
  if (!result.ok) {
    throw new Error(`df failed: ${result.stderr.trim() || "unknown error"}`);
  }
  const parsed = parseDf(result.stdout);
  if (!parsed) {
    throw new Error("could not parse df output");
  }
  return parsed;
}

export async function memoryInfo({ runCmd = defaultRun } = {}) {
  const [swapResult, pressureResult, vmResult] = await Promise.all([
    runCmd("sysctl", ["vm.swapusage"]),
    runCmd("sysctl", ["-n", "kern.memorystatus_vm_pressure_level"]),
    runCmd("vm_stat", []),
  ]);

  const swap = swapResult.ok
    ? parseSwap(swapResult.stdout)
    : { totalBytes: 0, usedBytes: 0, freeBytes: 0 };
  const parsedLevel = Number.parseInt(pressureResult.stdout.trim(), 10);
  const pressureLevel = Number.isFinite(parsedLevel) ? parsedLevel : 0;
  const pages = vmResult.ok ? parseVmStat(vmResult.stdout) : {};

  return {
    swap,
    pressureLevel,
    pressureLabel: pressureLabel(pressureLevel),
    wiredBytes: pageBytes(pages, "Pages wired down", DEFAULT_PAGE_SIZE),
    compressorBytes: pageBytes(
      pages,
      "Pages occupied by compressor",
      DEFAULT_PAGE_SIZE
    ),
    freeBytes: pageBytes(pages, "Pages free", DEFAULT_PAGE_SIZE),
  };
}
