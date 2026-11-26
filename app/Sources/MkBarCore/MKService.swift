import Foundation

public enum MKServiceError: Error, Sendable, Equatable, LocalizedError {
    case failed(status: Int32, detail: String)
    case invalidOutput(String)
    case noRules
    case cleanTimedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .failed(let status, let detail):
            return "mk failed with status \(status): \(detail)"
        case .invalidOutput(let detail):
            return "mk returned invalid JSON: \(detail)"
        case .noRules:
            return "No rules were selected for cleanup."
        case .cleanTimedOut(let seconds):
            return "Cleanup timed out after \(Int(seconds.rounded())) seconds. "
                + "Some caches may already be removed; refresh to see what remains."
        }
    }
}

/// The only gateway between the app and the CLI. It runs `mk` and decodes its
/// JSON; it never constructs, validates, or deletes any path itself.
public struct MKService: Sendable {
    private let locator: MKBinaries
    private let runner: any CommandRunning

    public init(
        locator: MKBinaries = MKBinaries(),
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.locator = locator
        self.runner = runner
    }

    public func loadReport() async throws -> Report {
        try await execute(arguments: ["report", "--json"], timeout: 90)
    }

    public func previewClean() async throws -> CleanResult {
        try await execute(arguments: ["clean", "--json"], timeout: 120)
    }

    /// Cleans only the given report-derived rule ids.
    ///
    /// Opt-in rules are never selected implicitly: `includeOptIn` is `false`
    /// by default, and when it is `true` the caller is asserting that the user
    /// explicitly asked for those rules.
    ///
    /// The argv order is stable and asserted by tests:
    /// `clean --yes --only <ids> [--include-opt-in] --json`.
    public func clean(ruleIDs: [String], includeOptIn: Bool = false) async throws -> CleanResult {
        // The CLI treats an empty `--only` list as "no filter", so a list of
        // blank ids must be rejected here: joining them would select every
        // non-opt-in rule instead of none. Valid ids are kebab-case, so
        // trimming cannot change a legitimate selection.
        let ids = ruleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            throw MKServiceError.noRules
        }

        var arguments = ["clean", "--yes", "--only", ids.joined(separator: ",")]
        if includeOptIn {
            arguments.append("--include-opt-in")
        }
        arguments.append("--json")

        do {
            return try await execute(arguments: arguments, timeout: 180)
        } catch let error as CommandError {
            if case .timedOut(let seconds) = error {
                // A killed clean is not transactional. Say so instead of
                // implying the cache state is unchanged.
                throw MKServiceError.cleanTimedOut(seconds: seconds)
            }
            throw error
        }
    }

    private func execute<T: Decodable>(arguments: [String], timeout: TimeInterval) async throws -> T {
        // Resolve per call: the user may have installed mk since the last run.
        let binary = try locator.locate()
        let command = Command(
            executable: binary.executable,
            arguments: binary.argumentsPrefix + arguments,
            environment: binary.environment,
            timeout: timeout
        )
        let output = try await runner.run(command)

        guard output.status == 0 else {
            let detail = output.stderrText.isEmpty
                ? "mk exited with status \(output.status)"
                : output.stderrText
            throw MKServiceError.failed(status: output.status, detail: detail)
        }

        do {
            return try JSONDecoder().decode(T.self, from: output.stdout)
        } catch {
            throw MKServiceError.invalidOutput(String(describing: error))
        }
    }
}
