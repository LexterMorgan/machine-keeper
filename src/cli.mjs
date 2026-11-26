import { readFileSync } from "node:fs";
import { appendFile, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { formatBytes } from "./bytes.mjs";
import { clean } from "./clean.mjs";
import { buildReport } from "./report.mjs";
import { loadRules, selectRules } from "./rules.mjs";
import { installSchedule, uninstallSchedule } from "./schedule.mjs";
import { auditStartup } from "./startup.mjs";

const COMMANDS = new Set([
  "report",
  "clean",
  "startup",
  "rules",
  "schedule",
  "help",
]);

const PACKAGE = JSON.parse(
  readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "package.json"),
    "utf8"
  )
);

export const VERSION = PACKAGE.version;

export const HELP = `machine-keeper ${VERSION} — keep a small Mac from filling up

Usage
  mk                     Show disk, memory, reclaimable caches, startup items
  mk report [--json]     Same, machine-readable with --json
  mk clean               Dry run: show what would be deleted
  mk clean --yes         Delete the included rules
  mk clean --only a,b    Limit to named rules
  mk clean --include-opt-in --yes
                         Include opt-in rules (app residue, old installers)
  mk startup [--json]    Audit launch agents, daemons, login items
  mk rules [--json]      List every rule
  mk schedule --install  Monthly report via launchd (never cleans)
  mk schedule --uninstall

Safety
  - Only home-relative paths listed in rules are touched.
  - Dry run by default; --yes is required to delete anything.
  - Skips a cache while its owning app is running.
  - Never uses sudo, never touches documents, never recurses into Downloads.
`;

/**
 * The exact object `mk report --json` emits: the read-only snapshot plus the
 * startup audit. Exported so the JSON contract test can pin the CLI shape
 * without touching the real home directory, and so future faces (app, web)
 * share one composition point.
 */
export async function buildFullReport({
  home,
  rules,
  now = () => new Date(),
  audit = auditStartup,
  ...reportOptions
}) {
  const report = await buildReport({ home, rules, now, ...reportOptions });
  report.startup = await audit({ home });
  return report;
}

export function parseArgs(argv) {
  const options = {
    command: "report",
    json: false,
    yes: false,
    only: [],
    includeOptIn: false,
    install: false,
    uninstall: false,
    help: false,
  };

  const rest = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--json") {
      options.json = true;
    } else if (arg === "--yes" || arg === "-y") {
      options.yes = true;
    } else if (arg === "--include-opt-in") {
      options.includeOptIn = true;
    } else if (arg === "--install") {
      options.install = true;
    } else if (arg === "--uninstall") {
      options.uninstall = true;
    } else if (arg === "--help" || arg === "-h") {
      options.help = true;
    } else if (arg === "--only") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--only needs a comma-separated rule list");
      }
      options.only.push(...value.split(",").map((id) => id.trim()).filter(Boolean));
      index += 1;
    } else if (arg.startsWith("--only=")) {
      options.only.push(
        ...arg.slice("--only=".length).split(",").map((id) => id.trim()).filter(Boolean)
      );
    } else if (arg.startsWith("-")) {
      throw new Error(`unknown flag: ${arg}`);
    } else {
      rest.push(arg);
    }
  }

  if (rest.length > 0) {
    const [command, ...extra] = rest;
    if (!COMMANDS.has(command)) {
      throw new Error(`unknown command: ${command}`);
    }
    if (extra.length > 0) {
      throw new Error(`unexpected argument: ${extra[0]}`);
    }
    options.command = command;
  }
  return options;
}

function pad(value, width) {
  return String(value).padEnd(width);
}

function padStart(value, width) {
  return String(value).padStart(width);
}

function printReport(report, out) {
  const lines = [];
  lines.push(`machine-keeper ${VERSION} — ${report.generatedAt.slice(0, 19).replace("T", " ")}`);
  lines.push("");

  if (report.disk) {
    lines.push(
      `Disk     ${formatBytes(report.disk.usedBytes)} used · ${formatBytes(
        report.disk.freeBytes
      )} free (${report.disk.percent} full)`
    );
  } else {
    lines.push("Disk     unavailable");
  }

  if (report.memory) {
    const { swap, pressureLabel, compressorBytes, totalBytes, usedBytes } = report.memory;
    const ram =
      totalBytes > 0
        ? usedBytes == null
          ? `RAM ${formatBytes(totalBytes)} · `
          : `RAM ${formatBytes(usedBytes)} of ${formatBytes(totalBytes)} · `
        : "";
    lines.push(
      `Memory   ${ram}swap ${formatBytes(swap.usedBytes)} of ${formatBytes(
        swap.totalBytes
      )} · pressure ${pressureLabel} · compressor ${formatBytes(compressorBytes)}`
    );
  } else {
    lines.push("Memory   unavailable");
  }
  lines.push("");

  const included = report.rows.filter((row) => !row.optIn && row.bytes > 0);
  const blocked = included.filter((row) => row.appRunning);
  const ready = included.filter((row) => !row.appRunning);

  lines.push(
    `Reclaimable  ${formatBytes(report.sweepableBytes)} across ${ready.length} rule${
      ready.length === 1 ? "" : "s"
    }`
  );
  for (const row of ready.sort((a, b) => b.bytes - a.bytes)) {
    lines.push(
      `  ${pad(row.id, 22)}${padStart(formatBytes(row.bytes), 10)}   ${row.risk}`
    );
  }
  for (const row of blocked.sort((a, b) => b.bytes - a.bytes)) {
    lines.push(
      `  ${pad(row.id, 22)}${padStart(formatBytes(row.bytes), 10)}   quit ${row.app} first`
    );
  }
  lines.push("");

  const optIn = report.optInRows.filter((row) => row.bytes > 0);
  if (optIn.length > 0) {
    lines.push(`Opt-in  ${formatBytes(report.optInBytes)} (excluded unless asked)`);
    for (const row of optIn.sort((a, b) => b.bytes - a.bytes)) {
      const detail = row.files > 1 ? `${row.files} files` : row.reclaim;
      lines.push(
        `  ${pad(row.id, 22)}${padStart(formatBytes(row.bytes), 10)}   ${detail}`
      );
    }
    lines.push("");
  }

  if (report.startup) {
    const { userAgents, systemAgents, systemDaemons, loginItems } = report.startup;
    const allAgents = [...userAgents, ...systemAgents, ...systemDaemons];
    const orphans = allAgents.filter((agent) => agent.status === "missing");
    lines.push(
      `Startup  ${userAgents.length} user agents · ${systemAgents.length} system agents · ` +
        `${systemDaemons.length} daemons · ${loginItems === null ? "?" : loginItems.length} login items`
    );
    for (const orphan of orphans) {
      lines.push(`  orphaned: ${orphan.label}`);
    }
    lines.push("");
  }

  lines.push("Next  mk clean            dry run");
  lines.push("      mk clean --yes      delete");
  out(lines.join("\n"));
}

function statusLabel(status) {
  switch (status) {
    case "removed":
      return "removed";
    case "would-remove":
      return "would remove";
    case "skipped-app-running":
      return "skip (running)";
    case "opt-in-skipped":
      return "skip (opt-in)";
    case "error":
      return "ERROR";
    default:
      return "missing";
  }
}

function printClean(result, out) {
  const lines = [];
  if (result.dryRun) {
    lines.push("Dry run — nothing was deleted. Add --yes to remove.");
  } else {
    lines.push(`Freed ${formatBytes(result.freedBytes)}.`);
  }
  lines.push("");
  const visible = result.results.filter((row) => row.status !== "missing");
  const missing = result.results.length - visible.length;
  for (const row of visible) {
    const label = statusLabel(row.status);
    lines.push(
      `  ${pad(label, 15)}${pad(row.id, 22)}${padStart(formatBytes(row.bytes), 10)}` +
        (row.error ? `   ${row.error}` : "")
    );
  }
  const pending = result.results
    .filter((row) => row.status === "would-remove")
    .reduce((sum, row) => sum + row.bytes, 0);
  if (missing > 0) {
    lines.push("");
    lines.push(`${missing} rule${missing === 1 ? "" : "s"} had nothing to reclaim.`);
  }
  if (result.dryRun && pending > 0) {
    lines.push(`Would free ${formatBytes(pending)}.`);
  }
  out(lines.join("\n"));
}

function printStartup(startup, out) {
  const sections = [
    ["User agents", startup.userAgents],
    ["System agents", startup.systemAgents],
    ["System daemons", startup.systemDaemons],
  ];
  const lines = ["Startup items"];
  for (const [title, rows] of sections) {
    lines.push("");
    lines.push(`${title} (${rows.length})`);
    for (const row of rows) {
      lines.push(`  ${pad(row.label, 56)}${row.status === "missing" ? "MISSING" : row.status}`);
    }
  }
  lines.push("");
  lines.push(
    `Login items: ${startup.loginItems === null ? "unavailable" : startup.loginItems.join(", ") || "none"}`
  );
  if (startup.brewServices !== null) {
    lines.push(
      `Brew services: ${
        startup.brewServices.map((service) => `${service.name} ${service.status}`).join(", ") || "none"
      }`
    );
  }
  out(lines.join("\n"));
}

function printRules(rules, out) {
  const lines = [`Rules (${rules.length})`];
  for (const rule of rules) {
    lines.push(
      `  ${pad(rule.id, 24)}${pad(rule.kind, 11)}${pad(rule.risk, 11)}${
        rule.optIn ? "opt-in" : ""
      }`
    );
  }
  out(lines.join("\n"));
}

async function recordRun(home, result, now) {
  try {
    const directory = path.join(home, ".local", "state", "machine-keeper");
    await mkdir(directory, { recursive: true });
    const line = JSON.stringify({
      at: now.toISOString(),
      freedBytes: result.freedBytes,
      rules: result.results
        .filter((row) => row.status === "removed")
        .map((row) => ({ id: row.id, bytes: row.bytes })),
    });
    await appendFile(path.join(directory, "runs.jsonl"), `${line}\n`, "utf8");
  } catch {
    // A missing state log must never fail a cleanup.
  }
}

export async function main(
  argv,
  { home = process.env.MK_HOME || os.homedir(), out = console.log, platform = process.platform, rulesFile } = {}
) {
  const options = parseArgs(argv);
  if (options.help || options.command === "help") {
    out(HELP);
    return 0;
  }
  if (platform !== "darwin") {
    out("machine-keeper supports macOS only right now. Linux and Windows ports are welcome.");
    return 2;
  }

  const loaded = loadRules({ file: rulesFile });

  if (options.command === "rules") {
    if (options.json) {
      out(JSON.stringify(loaded.rules, null, 2));
    } else {
      printRules(loaded.rules, out);
    }
    return 0;
  }

  if (options.command === "schedule") {
    const scriptPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "bin", "mk.mjs");
    if (options.uninstall) {
      const result = await uninstallSchedule({ home });
      out(`Removed ${result.path}`);
      return 0;
    }
    const result = await installSchedule({ home, scriptPath });
    out(`Wrote ${result.path}`);
    out(`Log: ${result.logFile}`);
    out(
      result.loaded
        ? "Loaded. This only reports; it never deletes."
        : `Could not load automatically: ${result.error}`
    );
    return 0;
  }

  if (options.command === "startup") {
    const startup = await auditStartup({ home });
    if (options.json) {
      out(JSON.stringify(startup, null, 2));
    } else {
      printStartup(startup, out);
    }
    return 0;
  }

  if (options.command === "clean") {
    const rules = selectRules(loaded.rules, {
      only: options.only,
      includeOptIn: options.includeOptIn,
    });
    const result = await clean({
      home,
      rules,
      dryRun: !options.yes,
      includeOptIn: options.includeOptIn,
      now: () => new Date(),
    });
    if (!result.dryRun) {
      await recordRun(home, result, new Date());
    }
    if (options.json) {
      out(JSON.stringify(result, null, 2));
    } else {
      printClean(result, out);
    }
    return 0;
  }

  const rules = selectRules(loaded.rules, { only: options.only, includeOptIn: true });
  const report = await buildFullReport({ home, rules, now: () => new Date() });
  if (options.json) {
    out(JSON.stringify(report, null, 2));
  } else {
    printReport(report, out);
  }
  return 0;
}
