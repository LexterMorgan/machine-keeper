import { execFile } from "node:child_process";

/**
 * Run a command and always resolve. Callers decide what a failure means.
 * No shell is involved, so arguments are never re-interpreted.
 */
export function run(command, args = [], { timeoutMs = 120_000 } = {}) {
  return new Promise((resolve) => {
    execFile(
      command,
      args,
      { timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024 },
      (error, stdout, stderr) => {
        resolve({
          ok: !error,
          code: error?.code ?? 0,
          stdout: stdout ?? "",
          stderr: stderr ?? "",
        });
      }
    );
  });
}
