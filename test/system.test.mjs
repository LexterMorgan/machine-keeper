import test from "node:test";
import assert from "node:assert/strict";
import { formatBytes, parseDuKilobytes } from "../src/bytes.mjs";
import {
  diskInfo,
  memoryInfo,
  parseDf,
  parseSwap,
  parseVmStat,
  pressureLabel,
} from "../src/system.mjs";

const DF = `Filesystem       1024-blocks      Used Available Capacity iused      ifree %iused  Mounted on
/dev/disk3s5       244785088 143654321  50000000    74%  2.4M   205M    1%   /System/Volumes/Data`;

const SWAP =
  "total = 9216.00M  used = 8181.38M  free = 1034.62M  (encrypted)";

const VM_STAT = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               3788.
Pages active:                            87945.
Pages wired down:                       134843.
Pages occupied by compressor:           174147.`;

test("formatBytes scales and rounds", () => {
  assert.equal(formatBytes(0), "0 B");
  assert.equal(formatBytes(-1), "0 B");
  assert.equal(formatBytes(512), "512 B");
  assert.equal(formatBytes(1024), "1.00 KB");
  assert.equal(formatBytes(1536), "1.50 KB");
  assert.equal(formatBytes(6.5 * 1024 ** 3), "6.50 GB");
  assert.equal(formatBytes(137.2 * 1024 ** 3), "137 GB");
});

test("parseDuKilobytes reads the du -sk first column", () => {
  assert.equal(parseDuKilobytes("1234\t/Users/lex/.npm\n"), 1234 * 1024);
  assert.equal(parseDuKilobytes(""), 0);
  assert.equal(parseDuKilobytes("garbage"), 0);
});

test("parseDf reads binary kilobytes and capacity", () => {
  const parsed = parseDf(DF);
  assert.equal(parsed.usedBytes, 143654321 * 1024);
  assert.equal(parsed.freeBytes, 50000000 * 1024);
  assert.equal(parsed.percent, "74%");
  assert.equal(parseDf("not a df table"), null);
});

test("parseSwap converts megabytes and gigabytes", () => {
  const parsed = parseSwap(SWAP);
  assert.equal(parsed.totalBytes, Math.round(9216 * 1024 ** 2));
  assert.equal(parsed.usedBytes, Math.round(8181.38 * 1024 ** 2));
  assert.equal(parseSwap("total = 1.00G used = 0.50G free = 0.50G").totalBytes, 1024 ** 3);
});

test("parseVmStat and pressureLabel", () => {
  const pages = parseVmStat(VM_STAT);
  assert.equal(pages["Pages wired down"], 134843);
  assert.equal(pages["Pages occupied by compressor"], 174147);
  assert.equal(pressureLabel(1), "normal");
  assert.equal(pressureLabel(2), "warning");
  assert.equal(pressureLabel(4), "critical");
  assert.equal(pressureLabel(3), "unknown");
});

test("diskInfo and memoryInfo use the injected runner", async () => {
  const fakeRun = async (command) => {
    if (command === "df") {
      return { ok: true, stdout: DF, stderr: "" };
    }
    if (command === "vm_stat") {
      return { ok: true, stdout: VM_STAT, stderr: "" };
    }
    if (command === "sysctl" ) {
      return { ok: true, stdout: "", stderr: "" };
    }
    return { ok: false, stdout: "", stderr: "" };
  };

  const swapRun = async (command, args) => {
    if (command === "sysctl" && args?.[0] === "vm.swapusage") {
      return { ok: true, stdout: SWAP, stderr: "" };
    }
    if (command === "sysctl" && args?.[0] === "-n") {
      return { ok: true, stdout: "2\n", stderr: "" };
    }
    return fakeRun(command);
  };

  const disk = await diskInfo({ runCmd: fakeRun });
  assert.equal(disk.percent, "74%");

  const memory = await memoryInfo({ runCmd: swapRun });
  assert.equal(memory.pressureLevel, 2);
  assert.equal(memory.pressureLabel, "warning");
  assert.equal(memory.wiredBytes, 134843 * 16384);
  assert.ok(memory.swap.usedBytes > 0);
});
