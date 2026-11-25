import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { clean } from "../src/clean.mjs";
import { buildFullReport, main } from "../src/cli.mjs";
import { JSON_SCHEMA_VERSION } from "../src/schema.mjs";
import { auditStartup } from "../src/startup.mjs";

const FIXED_NOW = new Date("2026-11-25T12:00:00.000Z");
const SIZES_KB = {
  "safe-cache": 1024,
  "spotify-cache": 2048,
  "old-installers": 4096,
};

// Rules as validateRules() returns them: the CLI never passes raw registry
// entries to the engine, so included rules always carry optIn: false.
const RULES = [
  {
    id: "safe-cache",
    title: "safe cache",
    kind: "delete",
    paths: ["Library/Caches/safe-cache"],
    risk: "rebuild",
    optIn: false,
  },
  {
    id: "spotify-cache",
    title: "Spotify cache",
    kind: "delete",
    paths: ["Library/Caches/spotify-cache"],
    risk: "rebuild",
    app: "Spotify",
    optIn: false,
  },
  {
    id: "old-installers",
    title: "old installers",
    kind: "delete",
    paths: ["Library/Caches/old-installers"],
    risk: "user-files",
    optIn: true,
    reclaim: "keep the ones you still need",
  },
];

async function withHome(fn) {
  const home = await mkdtemp(path.join(os.tmpdir(), "mk-report-"));
  try {
    return await fn(home);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function seed(home, relative, bytes = 4096) {
  const target = path.join(home, relative);
  await mkdir(target, { recursive: true });
  await writeFile(path.join(target, "blob.bin"), Buffer.alloc(bytes));
  return target;
}

async function seedRules(home) {
  const sizes = new Map();
  for (const rule of RULES) {
    const target = await seed(home, rule.paths[0]);
    sizes.set(target, SIZES_KB[rule.id]);
  }
  return sizes;
}

function duRunner(sizes) {
  return async (command, args) => {
    assert.equal(command, "du", `unexpected command: ${command}`);
    const target = args?.[1];
    assert.ok(sizes.has(target), `unexpected du target: ${target}`);
    return { ok: true, stdout: `${sizes.get(target)}\t${target}\n`, stderr: "" };
  };
}

function fakeSystem() {
  return {
    diskInfo: async () => ({
      totalBytes: 500 * 1024 ** 3,
      usedBytes: 400 * 1024 ** 3,
      freeBytes: 100 * 1024 ** 3,
      percent: "80%",
    }),
    memoryInfo: async () => ({
      swap: {
        totalBytes: 4 * 1024 ** 3,
        usedBytes: 1024 ** 3,
        freeBytes: 3 * 1024 ** 3,
      },
      pressureLevel: 1,
      pressureLabel: "normal",
      wiredBytes: 2 * 1024 ** 3,
      compressorBytes: 512 * 1024 ** 2,
      freeBytes: 1024 ** 3,
    }),
  };
}

async function fullReport(home, overrides = {}) {
  const sizes = await seedRules(home);
  const startup = {
    userAgents: [],
    systemAgents: [],
    systemDaemons: [],
    loginItems: [],
    brewServices: null,
  };
  const auditedHomes = [];
  const report = await buildFullReport({
    home,
    rules: RULES,
    now: () => FIXED_NOW,
    system: fakeSystem(),
    appRunning: async (app) => app === "Spotify",
    runCmd: duRunner(sizes),
    audit: async ({ home: audited }) => {
      auditedHomes.push(audited);
      return startup;
    },
    ...overrides,
  });
  return { report, startup, auditedHomes };
}

test("buildFullReport pins schema, generation time and reclaim sums", async () => {
  await withHome(async (home) => {
    const { report, startup, auditedHomes } = await fullReport(home);

    // Pin the literal as well as the constant: bumping JSON_SCHEMA_VERSION is
    // a deliberate breaking contract change, never a silent edit.
    assert.equal(JSON_SCHEMA_VERSION, 1);
    assert.equal(report.schemaVersion, JSON_SCHEMA_VERSION);
    assert.equal(typeof report.schemaVersion, "number");
    assert.ok(Number.isInteger(report.schemaVersion));
    assert.equal(report.generatedAt, FIXED_NOW.toISOString());
    assert.equal(report.generatedAt, "2026-11-25T12:00:00.000Z");
    assert.equal(typeof report.generatedAt, "string");
    assert.equal(report.home, home);
    assert.equal(typeof report.home, "string");

    assert.equal(typeof report.disk, "object");
    assert.notEqual(report.disk, null);
    assert.equal(report.disk.percent, "80%");
    assert.equal(typeof report.memory, "object");
    assert.notEqual(report.memory, null);
    assert.equal(report.memory.pressureLabel, "normal");

    assert.ok(Array.isArray(report.rows));
    assert.deepEqual(
      report.rows.map((row) => row.id),
      RULES.map((rule) => rule.id)
    );
    assert.ok(Array.isArray(report.optInRows));
    assert.deepEqual(
      report.optInRows.map((row) => row.id),
      ["old-installers"]
    );

    for (const key of ["sweepableBytes", "blockedBytes", "optInBytes"]) {
      assert.equal(typeof report[key], "number", key);
      assert.ok(Number.isFinite(report[key]), key);
      assert.ok(report[key] >= 0, key);
    }
    assert.equal(report.sweepableBytes, SIZES_KB["safe-cache"] * 1024);
    assert.equal(report.blockedBytes, SIZES_KB["spotify-cache"] * 1024);
    assert.equal(report.optInBytes, SIZES_KB["old-installers"] * 1024);
    assert.equal(
      report.sweepableBytes + report.blockedBytes + report.optInBytes,
      report.rows.reduce((sum, row) => sum + row.bytes, 0)
    );

    assert.equal(typeof report.startup, "object");
    assert.notEqual(report.startup, null);
    assert.deepEqual(report.startup, startup);
    assert.deepEqual(auditedHomes, [home]);
  });
});

test("report rows expose the documented consumer contract", async () => {
  await withHome(async (home) => {
    const { report } = await fullReport(home);

    assert.equal(report.rows.length, 3);
    for (const row of report.rows) {
      assert.equal(typeof row.id, "string");
      assert.ok(row.id.length > 0);
      assert.equal(typeof row.title, "string");
      assert.ok(row.title.length > 0);
      assert.equal(typeof row.risk, "string");
      assert.ok(row.risk.length > 0);
      assert.equal(typeof row.optIn, "boolean");
      assert.ok(row.app === null || typeof row.app === "string");
      assert.equal(typeof row.appRunning, "boolean");
      assert.equal(typeof row.reclaim, "string");
      assert.equal(typeof row.bytes, "number");
      assert.ok(Number.isInteger(row.bytes));
      assert.ok(row.bytes >= 0);
      assert.equal(typeof row.files, "number");
      assert.ok(Number.isInteger(row.files));
      assert.ok(row.files >= 0);
    }

    const byId = Object.fromEntries(report.rows.map((row) => [row.id, row]));

    assert.equal(byId["safe-cache"].optIn, false);
    assert.equal(byId["safe-cache"].app, null);
    assert.equal(byId["safe-cache"].appRunning, false);
    assert.equal(byId["safe-cache"].bytes, SIZES_KB["safe-cache"] * 1024);
    assert.equal(byId["safe-cache"].files, 1);

    assert.equal(byId["spotify-cache"].optIn, false);
    assert.equal(byId["spotify-cache"].app, "Spotify");
    assert.equal(byId["spotify-cache"].appRunning, true);
    assert.equal(byId["spotify-cache"].bytes, SIZES_KB["spotify-cache"] * 1024);

    assert.equal(byId["old-installers"].optIn, true);
    assert.equal(byId["old-installers"].app, null);
    assert.equal(byId["old-installers"].reclaim, "keep the ones you still need");
    assert.equal(byId["old-installers"].bytes, SIZES_KB["old-installers"] * 1024);
    assert.ok(report.optInRows.includes(byId["old-installers"]));
    assert.deepEqual(
      report.optInRows.map((row) => row.optIn),
      [true]
    );
  });
});

test("disk and memory are null when probes throw, rows still return", async () => {
  await withHome(async (home) => {
    const { report } = await fullReport(home, {
      system: {
        diskInfo: async () => {
          throw new Error("df unavailable");
        },
        memoryInfo: async () => {
          throw new Error("sysctl unavailable");
        },
      },
    });

    assert.equal(report.disk, null);
    assert.equal(report.memory, null);
    assert.equal(report.rows.length, 3);
    assert.ok(report.rows.every((row) => typeof row.bytes === "number"));
    assert.equal(report.sweepableBytes, SIZES_KB["safe-cache"] * 1024);
    assert.equal(report.blockedBytes, SIZES_KB["spotify-cache"] * 1024);
    assert.equal(report.optInBytes, SIZES_KB["old-installers"] * 1024);
  });
});

test("auditStartup keeps the documented startup contract", async () => {
  await withHome(async (home) => {
    const agents = path.join(home, "Library", "LaunchAgents");
    await mkdir(agents, { recursive: true });
    await writeFile(path.join(agents, "com.example.orphan.plist"), "<plist/>");
    await writeFile(path.join(agents, "notes.txt"), "ignored");

    const startup = await auditStartup({
      home,
      runCmd: async () => ({ ok: false, stdout: "", stderr: "unavailable" }),
      readPlistFn: async () => ({
        Program: "/Applications/Gone.app/Contents/MacOS/Gone",
      }),
      exists: () => false,
    });

    assert.ok(Array.isArray(startup.userAgents));
    assert.ok(Array.isArray(startup.systemAgents));
    assert.ok(Array.isArray(startup.systemDaemons));
    assert.ok(startup.loginItems === null || Array.isArray(startup.loginItems));
    assert.ok(startup.brewServices === null || Array.isArray(startup.brewServices));
    assert.equal(startup.loginItems, null);
    assert.equal(startup.brewServices, null);

    assert.equal(startup.userAgents.length, 1);
    assert.equal(startup.userAgents[0].label, "com.example.orphan");
    assert.equal(startup.userAgents[0].status, "missing");

    const entries = [
      ...startup.userAgents,
      ...startup.systemAgents,
      ...startup.systemDaemons,
    ];
    for (const entry of entries) {
      assert.equal(typeof entry.label, "string");
      assert.ok(entry.label.length > 0);
      assert.equal(typeof entry.file, "string");
      assert.ok(path.isAbsolute(entry.file));
      assert.ok(entry.program === null || typeof entry.program === "string");
      assert.ok(["present", "missing", "unknown"].includes(entry.status));
    }
  });
});

test("clean dry run pins schemaVersion, dryRun and result rows", async () => {
  await withHome(async (home) => {
    const target = await seed(home, "Library/Caches/clean-me", 8192);
    const result = await clean({
      home,
      rules: [
        {
          id: "clean-me",
          title: "clean me",
          kind: "delete",
          paths: ["Library/Caches/clean-me"],
          risk: "rebuild",
        },
      ],
      dryRun: true,
      appRunning: async () => false,
      runCmd: duRunner(new Map([[target, 8]])),
    });

    assert.equal(result.schemaVersion, JSON_SCHEMA_VERSION);
    assert.equal(typeof result.schemaVersion, "number");
    assert.ok(Number.isInteger(result.schemaVersion));
    assert.equal(typeof result.dryRun, "boolean");
    assert.equal(result.dryRun, true);
    assert.equal(typeof result.freedBytes, "number");
    assert.equal(result.freedBytes, 0);
    assert.ok(Array.isArray(result.results));
    assert.equal(result.results.length, 1);

    const [row] = result.results;
    assert.equal(typeof row.id, "string");
    assert.equal(row.id, "clean-me");
    assert.equal(typeof row.title, "string");
    assert.equal(row.title, "clean me");
    assert.equal(typeof row.bytes, "number");
    assert.equal(row.bytes, 8 * 1024);
    assert.equal(row.status, "would-remove");
    assert.equal("error" in row, false);
  });
});

test("main clean --json emits the contract on stdout and deletes nothing", async () => {
  await withHome(async (home) => {
    const seededBytes = 64 * 1024;
    const cache = await seed(home, "Library/Caches/cli-clean-cache", seededBytes);
    const rulesFile = path.join(home, "rules.json");
    await writeFile(
      rulesFile,
      JSON.stringify({
        schemaVersion: 1,
        rules: [
          {
            id: "cli-clean-cache",
            title: "cli clean cache",
            kind: "delete",
            paths: ["Library/Caches/cli-clean-cache"],
            risk: "rebuild",
          },
        ],
      })
    );

    const lines = [];
    const code = await main(["clean", "--json"], {
      home,
      rulesFile,
      platform: "darwin",
      out: (line) => lines.push(line),
    });

    assert.equal(code, 0);
    assert.ok(lines.length > 0);

    // This is the exact stdout the app parses, so the whole stream must be one
    // JSON document.
    const result = JSON.parse(lines.join("\n"));
    assert.equal(result.schemaVersion, 1);
    assert.equal(typeof result.schemaVersion, "number");
    assert.ok(Number.isInteger(result.schemaVersion));
    assert.equal(typeof result.dryRun, "boolean");
    assert.equal(result.dryRun, true);
    assert.equal(typeof result.freedBytes, "number");
    assert.equal(result.freedBytes, 0);
    assert.ok(Array.isArray(result.results));
    assert.equal(result.results.length, 1);

    const [row] = result.results;
    assert.equal(row.id, "cli-clean-cache");
    assert.equal(row.title, "cli clean cache");
    assert.equal(row.status, "would-remove");
    assert.equal(typeof row.bytes, "number");
    assert.ok(Number.isInteger(row.bytes));
    assert.ok(row.bytes > 0);
    assert.equal("error" in row, false);

    // A dry run must leave the seeded cache byte-for-byte in place.
    assert.equal((await stat(cache)).isDirectory(), true);
    const blobStat = await stat(path.join(cache, "blob.bin"));
    assert.equal(blobStat.isFile(), true);
    assert.equal(blobStat.size, seededBytes);
  });
});
