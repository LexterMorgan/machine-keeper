import Darwin
import Dispatch
import Foundation

/// Runs commands without a shell, capturing each stream to its own temporary
/// file so a chatty child cannot fill a pipe and deadlock.
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
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            throw CommandError.launchFailed("could not create a temporary directory: \(error.localizedDescription)")
        }
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let stdoutURL = directory.appendingPathComponent("stdout", isDirectory: false)
        let stderrURL = directory.appendingPathComponent("stderr", isDirectory: false)

        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil)
        else {
            throw CommandError.launchFailed("could not create temporary output files")
        }

        let stdoutHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        } catch {
            throw CommandError.launchFailed("could not open the temporary output file: \(error.localizedDescription)")
        }

        let stderrHandle: FileHandle
        do {
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            try? stdoutHandle.close()
            throw CommandError.launchFailed("could not open the temporary error file: \(error.localizedDescription)")
        }

        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed("\(command.executable.path): \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(command.timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                if process.isRunning {
                    process.terminate()
                }
                let graceDeadline = Date().addingTimeInterval(terminationGracePeriod)
                while process.isRunning && Date() < graceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        // Always reap the child before reading or throwing: leaving it running
        // past the temporary-file cleanup would leak a zombie.
        process.waitUntilExit()

        stdoutHandle.synchronizeFile()
        stderrHandle.synchronizeFile()

        if timedOut {
            throw CommandError.timedOut(seconds: command.timeout)
        }

        do {
            let stdout = try Data(contentsOf: stdoutURL)
            let stderr = try Data(contentsOf: stderrURL)
            return CommandOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            throw CommandError.launchFailed("could not read the captured output: \(error.localizedDescription)")
        }
    }
}
