import Darwin
import Dispatch
import Foundation

/// Runs commands without a shell, capturing each stream to its own temporary
/// file so a chatty child cannot fill a pipe and deadlock.
///
/// The child is spawned as its own process-group leader. On timeout the whole
/// group is signalled, so helpers that `mk` started (`du`, `npm`, `brew`, …)
/// cannot outlive the command and keep the cache busy.
public struct ProcessCommandRunner: CommandRunning {
    private let temporaryRoot: URL
    private let terminationGracePeriod: TimeInterval

    public init() {
        self.temporaryRoot = FileManager.default.temporaryDirectory
        self.terminationGracePeriod = 2.0
    }

    /// Test seam: lets the suite prove every path cleans up its scratch
    /// directory and exercises the SIGKILL escalation without waiting out the
    /// production grace period.
    internal init(temporaryRoot: URL, terminationGracePeriod: TimeInterval = 2.0) {
        self.temporaryRoot = temporaryRoot
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(_ command: Command) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandOutput, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.execute(command))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute(_ command: Command) throws -> CommandOutput {
        let fileManager = FileManager.default
        let directory = temporaryRoot
            .appendingPathComponent("mkbar-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CommandError.launchFailed("could not create a temporary directory: \(error.localizedDescription)")
        }
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let stdoutURL = directory.appendingPathComponent("stdout", isDirectory: false)
        let stderrURL = directory.appendingPathComponent("stderr", isDirectory: false)

        let stdoutFD = open(stdoutURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard stdoutFD >= 0 else {
            throw CommandError.launchFailed("could not create the temporary output file")
        }
        let stderrFD = open(stderrURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard stderrFD >= 0 else {
            _ = close(stdoutFD)
            throw CommandError.launchFailed("could not create the temporary error file")
        }
        defer {
            _ = close(stdoutFD)
            _ = close(stderrFD)
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CommandError.launchFailed("could not prepare spawn file actions")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        guard posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stdoutFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stderrFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stdoutFD) == 0,
              posix_spawn_file_actions_addclose(&fileActions, stderrFD) == 0
        else {
            throw CommandError.launchFailed("could not prepare the child's file descriptors")
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CommandError.launchFailed("could not prepare spawn attributes")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawnattr_setflags(
                  &attributes,
                  Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
              ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw CommandError.launchFailed("could not prepare the child's process group")
        }

        // The parent may have SIGTERM blocked or ignored (test runners and app
        // hosts sometimes do). Reset the mask and disposition so the grace
        // period actually gives the child a chance to exit before SIGKILL.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        guard posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
        else {
            throw CommandError.launchFailed("could not reset the child's signal state")
        }

        let argv = try Self.makeCStringArray([command.executable.path] + command.arguments)
        defer {
            Self.freeCStringArray(argv)
        }
        let envp = try Self.makeCStringArray(
            command.environment.map { "\($0.key)=\($0.value)" }.sorted()
        )
        defer {
            Self.freeCStringArray(envp)
        }

        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                command.executable.path.withCString { pathPointer in
                    posix_spawn(
                        &pid,
                        pathPointer,
                        &fileActions,
                        &attributes,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
        }

        guard spawnResult == 0 else {
            throw CommandError.launchFailed(
                "\(command.executable.path): \(String(cString: strerror(spawnResult)))"
            )
        }

        let outcome = try wait(for: pid, timeout: command.timeout)
        if outcome.timedOut {
            throw CommandError.timedOut(seconds: command.timeout)
        }

        do {
            let stdout = try Data(contentsOf: stdoutURL)
            let stderr = try Data(contentsOf: stderrURL)
            return CommandOutput(
                status: Self.exitCode(from: outcome.status),
                stdout: stdout,
                stderr: stderr
            )
        } catch {
            throw CommandError.launchFailed("could not read the captured output: \(error.localizedDescription)")
        }
    }

    /// Waits for the child, escalating from SIGTERM to SIGKILL across its whole
    /// process group when the deadline passes.
    private func wait(for pid: pid_t, timeout: TimeInterval) throws -> (timedOut: Bool, status: Int32) {
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                return (false, status)
            }
            if result < 0 {
                throw CommandError.launchFailed(
                    "waitpid failed for \(pid): \(String(cString: strerror(errno)))"
                )
            }
            if Date() >= deadline {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        // The child is the group leader, so a negative pid signals every helper
        // it started. SIGTERM first, a short grace, then SIGKILL.
        _ = kill(-pid, SIGTERM)

        // Do not reap the leader during the grace period. A zombie leader keeps
        // its pid reserved, which keeps the process-group ID from being reused
        // until the group has been signalled. If the group disappears early
        // (leader and helpers both exited), stop waiting.
        let graceDeadline = Date().addingTimeInterval(terminationGracePeriod)
        while Date() < graceDeadline {
            if !groupExists(pid) {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        // Signal the group before reaping the leader. A leader that exited on
        // SIGTERM is a zombie here, not a reused pid, so this cannot hit an
        // unrelated process group. SIGKILL also terminates helpers that
        // ignored the earlier SIGTERM.
        _ = kill(-pid, SIGKILL)

        // Wait for the group to disappear before reaping the leader. The
        // leader's zombie keeps the group identifier reserved while helpers
        // finish; do not send any further signals after waitpid.
        let settleDeadline = Date().addingTimeInterval(
            min(1.0, max(0.2, terminationGracePeriod))
        )
        while Date() < settleDeadline {
            if !groupExists(pid) {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let reaped = waitpid(pid, &status, 0)
        if reaped < 0 {
            throw CommandError.launchFailed(
                "could not reap \(pid) after timeout: \(String(cString: strerror(errno)))"
            )
        }
        return (true, status)
    }

    /// `kill(-pgid, 0)` is a liveness probe, not a destructive signal. While
    /// the leader is still unreaped, the group ID cannot be reused.
    private func groupExists(_ pgid: pid_t) -> Bool {
        if kill(-pgid, 0) == 0 {
            return true
        }
        // On macOS an empty group whose only member is an unreaped zombie
        // leader reports EPERM, not ESRCH. The leader is still owned by us and
        // unreaped, so the group ID cannot have been reused; treat both as gone.
        return errno != ESRCH && errno != EPERM
    }

    /// `waitpid` status follows the shell convention: 128 + signal for a
    /// signal death, otherwise the exit code.
    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func makeCStringArray(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStringArray(pointers)
                throw CommandError.launchFailed("could not allocate command arguments")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private static func freeCStringArray(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            if let pointer {
                free(pointer)
            }
        }
    }
}
