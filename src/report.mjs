import { findInstallers } from "./installers.mjs";
import { diskInfo, memoryInfo } from "./system.mjs";
import { isAppRunning, measureRule } from "./targets.mjs";

async function capture(fn) {
  try {
    return await fn();
  } catch {
    return null;
  }
}

/**
 * Read-only snapshot of disk, memory, every rule's footprint, and startup
 * state. Pure of side effects: safe to call on every `mk` run.
 */
export async function buildReport({
  home,
  rules,
  runCmd,
  now = () => new Date(),
  appRunning = isAppRunning,
  system = { diskInfo, memoryInfo },
}) {
  const disk = await capture(() => system.diskInfo({ runCmd }));
  const memory = await capture(() => system.memoryInfo({ runCmd }));

  const rows = [];
  for (const rule of rules) {
    const running = rule.app ? await appRunning(rule.app, { runCmd }) : false;
    let bytes = 0;
    let files = 0;

    if (rule.kind === "installers") {
      const found = await findInstallers({ home, rule, now: now() });
      bytes = found.reduce((sum, file) => sum + file.bytes, 0);
      files = found.length;
    } else {
      const measured = await measureRule(home, rule, { runCmd });
      bytes = measured.totalBytes;
      files = measured.parts.length;
    }

    rows.push({
      id: rule.id,
      title: rule.title,
      risk: rule.risk,
      optIn: rule.optIn,
      app: rule.app ?? null,
      appRunning: running,
      reclaim: rule.reclaim ?? "",
      bytes,
      files,
    });
  }

  const included = rows.filter((row) => !row.optIn);
  const optIn = rows.filter((row) => row.optIn);

  return {
    generatedAt: now().toISOString(),
    home,
    disk,
    memory,
    rows,
    optInRows: optIn,
    sweepableBytes: included
      .filter((row) => !row.appRunning)
      .reduce((sum, row) => sum + row.bytes, 0),
    blockedBytes: included
      .filter((row) => row.appRunning)
      .reduce((sum, row) => sum + row.bytes, 0),
    optInBytes: optIn.reduce((sum, row) => sum + row.bytes, 0),
  };
}
