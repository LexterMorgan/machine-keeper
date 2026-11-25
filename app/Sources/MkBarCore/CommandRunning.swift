import Foundation

/// A single subprocess invocation. No shell is involved: `executable` is run
/// directly with `arguments`.
public struct Command: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct CommandOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Lossy UTF-8 decoding with surrounding whitespace removed.
    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async throws -> CommandOutput
}

public enum CommandError: Error, Sendable, Equatable, LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not launch the command: \(message)"
        case .timedOut(let seconds):
            return "The command timed out after \(seconds) seconds."
        }
    }
}
