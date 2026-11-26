import test from "node:test";
import assert from "node:assert/strict";
import { formatBytes, parseDuKilobytes } from "../src/bytes.mjs";
import {
  diskInfo,
  memoryInfo,
  parseDf,
  parsePageSize,
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
Pages purgeable:                             2.
Pages wired down:                       134843.
File-backed pages:                       54335.
Anonymous pages:                         89430.
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

test("parseVmStat, parsePageSize, and pressureLabel", () => {
  const pages = parseVmStat(VM_STAT);
  assert.equal(pages["Pages wired down"], 134843);
  assert.equal(pages["Pages occupied by compressor"], 174147);
  assert.equal(parsePageSize(VM_STAT), 16384);
  assert.equal(parsePageSize("page size of 4096 bytes"), 4096);
  assert.equal(parsePageSize("unknown"), 16384);
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
    if (command === "sysctl" && args?.[0] === "-n" && args?.[1] === "hw.memsize") {
      return { ok: true, stdout: "8589934592\n", stderr: "" };
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
  assert.equal(memory.totalBytes, 8589934592);
  assert.equal(memory.wiredBytes, 134843 * 16384);
  assert.equal(memory.compressorBytes, 174147 * 16384);
  assert.equal(memory.appBytes, (89430 - 2) * 16384);
  assert.equal(memory.cachedBytes, 54335 * 16384);
  assert.equal(memory.usedBytes, (89430 - 2 + 134843 + 174147) * 16384);
  assert.equal(memory.freeBytes, 3788 * 16384);
  assert.ok(memory.swap.usedBytes > 0);
});

test("memoryInfo uses null for counters macOS did not report", async () => {
  const vmStat = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               10.
Pages wired down:                        20.
Pages occupied by compressor:            30.`;

  const memory = await memoryInfo({
    runCmd: async (command, args) => {
      if (command === "vm_stat") {
        return { ok: true, stdout: vmStat, stderr: "" };
      }
      if (command === "sysctl" && args?.[0] === "-n") {
        return {
          ok: true,
          stdout: args?.[1] === "hw.memsize" ? "8589934592\n" : "2\n",
          stderr: "",
        };
      }
      return { ok: true, stdout: "", stderr: "" };
    },
  });

  assert.equal(memory.totalBytes, 8589934592);
  assert.equal(memory.appBytes, null);
  assert.equal(memory.cachedBytes, null);
  assert.equal(memory.usedBytes, null);
  assert.equal(memory.wiredBytes, 20 * 16384);
});
