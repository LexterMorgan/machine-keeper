import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  auditDirectory,
  brewServices,
  loginItems,
  orphanStatus,
  programOf,
} from "../src/startup.mjs";

test("programOf reads Program and ProgramArguments", () => {
  assert.equal(programOf({ Program: "/a/b" }), "/a/b");
  assert.equal(programOf({ ProgramArguments: ["/a/c", "--flag"] }), "/a/c");
  assert.equal(programOf({ ProgramArguments: [] }), null);
  assert.equal(programOf(null), null);
});

test("orphanStatus distinguishes missing programs from unknown ones", () => {
  assert.equal(orphanStatus("/Applications/Gone.app/x", { exists: () => false }), "missing");
  assert.equal(orphanStatus("/Applications/Here.app/x", { exists: () => true }), "present");
  assert.equal(orphanStatus("steamclean", { exists: () => true }), "unknown");
  assert.equal(orphanStatus(null, { exists: () => true }), "unknown");
});

test("auditDirectory flags plists whose program is gone", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "mk-agents-"));
  try {
    await writeFile(path.join(directory, "com.example.gone.plist"), "<plist/>");
    await writeFile(path.join(directory, "com.example.here.plist"), "<plist/>");
    await writeFile(path.join(directory, "notes.txt"), "ignored");

    const rows = await auditDirectory(directory, {
      readPlistFn: async (file) =>
        file.endsWith("gone.plist")
          ? { Program: "/Applications/Gone.app/Contents/MacOS/Gone" }
          : { Program: "/Applications/Here.app/Contents/MacOS/Here" },
      exists: (target) => target.includes("Here.app"),
    });

    assert.equal(rows.length, 2);
    const byLabel = Object.fromEntries(rows.map((row) => [row.label, row.status]));
    assert.equal(byLabel["com.example.gone"], "missing");
    assert.equal(byLabel["com.example.here"], "present");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("auditDirectory returns empty when the directory is absent", async () => {
  const rows = await auditDirectory("/nonexistent/agents", { readPlistFn: async () => null });
  assert.deepEqual(rows, []);
});

test("loginItems and brewServices parse tool output", async () => {
  const runCmd = async (command, args) => {
    if (command === "osascript") {
      return { ok: true, stdout: "AlDente, Dropover, WhatsApp\n", stderr: "" };
    }
    if (command === "brew" && args?.[0] === "services") {
      return {
        ok: true,
        stdout: "Name          Status  User File\npostgresql@18 started lex  ~/Library/LaunchAgents/x.plist\nmongodb       none\n",
        stderr: "",
      };
    }
    return { ok: false, stdout: "", stderr: "" };
  };

  assert.deepEqual(await loginItems({ runCmd }), ["AlDente", "Dropover", "WhatsApp"]);
  assert.deepEqual(await brewServices({ runCmd }), [
    { name: "postgresql@18", status: "started" },
    { name: "mongodb", status: "none" },
  ]);
});

test("unavailable tools return null instead of throwing", async () => {
  const runCmd = async () => ({ ok: false, stdout: "", stderr: "not found" });
  assert.equal(await loginItems({ runCmd }), null);
  assert.equal(await brewServices({ runCmd }), null);
});
