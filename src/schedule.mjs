import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { run as defaultRun } from "./exec.mjs";

export const LABEL = "dev.machinekeeper.monthly";

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

export function plistPath(home) {
  return path.join(home, "Library", "LaunchAgents", `${LABEL}.plist`);
}

export function logPath(home) {
  return path.join(home, "Library", "Logs", "machine-keeper.log");
}

/** Monthly report at 09:00 on the first day. Never cleans automatically. */
export function renderPlist({ nodePath, scriptPath, logFile }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escapeXml(nodePath)}</string>
    <string>${escapeXml(scriptPath)}</string>
    <string>report</string>
    <string>--json</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Day</key>
    <integer>1</integer>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${escapeXml(logFile)}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(logFile)}</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
`;
}

export async function installSchedule({
  home,
  scriptPath,
  nodePath = process.execPath,
  runCmd = defaultRun,
}) {
  const target = plistPath(home);
  const logFile = logPath(home);
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, renderPlist({ nodePath, scriptPath, logFile }), "utf8");

  const uid = typeof process.getuid === "function" ? process.getuid() : 501;
  const result = await runCmd("launchctl", ["bootstrap", `gui/${uid}`, target]);
  return {
    path: target,
    logFile,
    loaded: result.ok,
    error: result.ok ? null : result.stderr.trim() || "launchctl bootstrap failed",
  };
}

export async function uninstallSchedule({ home, runCmd = defaultRun }) {
  const target = plistPath(home);
  const uid = typeof process.getuid === "function" ? process.getuid() : 501;
  await runCmd("launchctl", ["bootout", `gui/${uid}`, target]);
  await rm(target, { force: true });
  return { path: target };
}
