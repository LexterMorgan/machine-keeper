import Foundation
import Testing
import MkBarCore

@Suite("MK service")
struct MKServiceTests {
    private let mkPath = "/opt/test/bin/mk"

    @Test func loadReportRunsReportJSON() async throws {
        let runner = RecordingRunner(commandOutput: try Self.successOutput(TestFixtures.reportData()))
        let service = makeService(runner: runner)

        let report = try await service.loadReport()

        #expect(report.rows.count == 5)
        let commands = await runner.recordedCommands()
        let command = try #require(commands.first)
        #expect(command.executable.path == mkPath)
        #expect(command.arguments == ["report", "--json"])
        #expect(command.timeout == 90)
    }

    @Test func previewCleanRunsCleanJSON() async throws {
        let runner = RecordingRunner(commandOutput: Self.successOutput(TestFixtures.cleanJSON))
        let service = makeService(runner: runner)

        let result = try await service.previewClean()

        #expect(result.dryRun)
        #expect(result.results.count == 4)
        #expect(result.results[0].cleanStatus == .wouldRemove)

        let commands = await runner.recordedCommands()
        let command = try #require(commands.first)
        #expect(command.arguments == ["clean", "--json"])
        #expect(command.arguments.contains("--json"))
        #expect(!command.arguments.contains("--yes"))
        #expect(command.timeout == 120)
    }

    @Test func cleanPassesSelectedRuleIDs() async throws {
        let runner = RecordingRunner(commandOutput: Self.successOutput(TestFixtures.cleanJSON))
        let service = makeService(runner: runner)

        let result = try await service.clean(ruleIDs: ["npm-cache", "pip-cache"])

        #expect(result.results.count == 4)
        let commands = await runner.recordedCommands()
        let command = try #require(commands.first)
        #expect(command.arguments == ["clean", "--yes", "--only", "npm-cache,pip-cache", "--json"])
        #expect(command.arguments.contains("--json"))
        #expect(command.arguments.contains("--yes"))
        #expect(!command.arguments.contains("--include-opt-in"))
        #expect(command.timeout == 180)
    }

    @Test func cleanTrimsRuleIDs() async throws {
        let runner = RecordingRunner(commandOutput: Self.successOutput(TestFixtures.cleanJSON))
        let service = makeService(runner: runner)

        _ = try await service.clean(ruleIDs: [" npm-cache ", "", "\tpip-cache\n"])

        let commands = await runner.recordedCommands()
        let command = try #require(commands.first)
        #expect(command.arguments == ["clean", "--yes", "--only", "npm-cache,pip-cache", "--json"])
    }

    @Test func cleanWithOnlyBlankRuleIDsThrowsAndRunsNothing() async throws {
        let runner = RecordingRunner(commandOutput: Self.successOutput(TestFixtures.cleanJSON))
        let service = makeService(runner: runner)

        do {
            _ = try await service.clean(ruleIDs: ["", "   ", "\n\t"])
            Issue.record("Expected clean to throw")
        } catch let error as MKServiceError {
            #expect(error == .noRules)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = await runner.recordedCommands()
        #expect(commands.isEmpty)
    }

    @Test func cleanWithNoRulesThrowsAndRunsNothing() async throws {
        let runner = RecordingRunner(commandOutput: Self.successOutput(TestFixtures.cleanJSON))
        let service = makeService(runner: runner)

        do {
            _ = try await service.clean(ruleIDs: [])
            Issue.record("Expected clean to throw")
        } catch let error as MKServiceError {
            #expect(error == .noRules)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let commands = await runner.recordedCommands()
        #expect(commands.isEmpty)
    }

    @Test func childEnvironmentCarriesAugmentedPATH() async throws {
        let runner = RecordingRunner(commandOutput: try Self.successOutput(TestFixtures.reportData()))
        let service = makeService(runner: runner)

        _ = try await service.loadReport()

        let commands = await runner.recordedCommands()
        let command = try #require(commands.first)
        #expect(command.environment["MK_BIN"] == mkPath)
        let pathEntries = try #require(command.environment["PATH"]).split(separator: ":").map(String.init)
        #expect(pathEntries.first == "/opt/test/bin")
        #expect(pathEntries.contains("/usr/bin"))
        #expect(pathEntries.contains("/bin"))
    }

    @Test func nonZeroStatusSurfacesStderr() async throws {
        let runner = RecordingRunner(
            commandOutput: CommandOutput(
                status: 1,
                stdout: Data(),
                stderr: Data("permission denied\n".utf8)
            )
        )
        let service = makeService(runner: runner)

        do {
            _ = try await service.loadReport()
            Issue.record("Expected loadReport to throw")
        } catch let error as MKServiceError {
            #expect(error == .failed(status: 1, detail: "permission denied"))
            #expect(error.localizedDescription.contains("permission denied"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func nonZeroStatusWithoutStderrUsesExitCodeMessage() async throws {
        let runner = RecordingRunner(
            commandOutput: CommandOutput(status: 2, stdout: Data(), stderr: Data())
        )
        let service = makeService(runner: runner)

        do {
            _ = try await service.loadReport()
            Issue.record("Expected loadReport to throw")
        } catch let error as MKServiceError {
            #expect(error == .failed(status: 2, detail: "mk exited with status 2"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func nonZeroStatusWithWhitespaceOnlyStderrUsesExitCodeMessage() async throws {
        let runner = RecordingRunner(
            commandOutput: CommandOutput(status: 3, stdout: Data(), stderr: Data("  \n\t\n".utf8))
        )
        let service = makeService(runner: runner)

        do {
            _ = try await service.loadReport()
            Issue.record("Expected loadReport to throw")
        } catch let error as MKServiceError {
            #expect(error == .failed(status: 3, detail: "mk exited with status 3"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func locatorIsResolvedOnEveryCall() async throws {
        let runner = RecordingRunner(commandOutput: try Self.successOutput(TestFixtures.reportData()))
        let executable = MutableExecutableCheck(path: mkPath)
        let locator = MKBinaries(
            environment: ["MK_BIN": mkPath, "PATH": "/usr/bin:/bin"],
            home: URL(fileURLWithPath: "/Users/tester"),
            isExecutable: { executable.isAllowed($0) }
        )
        let service = MKService(locator: locator, runner: runner)

        // The first call fails to resolve mk and must not run anything.
        do {
            _ = try await service.loadReport()
            Issue.record("Expected locate() to fail")
        } catch let error as LocatorError {
            #expect(error == .notExecutable(path: mkPath))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await runner.recordedCommands().isEmpty)

        // Installing mk between calls must be picked up without a new service.
        executable.setAllowed(true)
        let report = try await service.loadReport()
        #expect(report.rows.count == 5)
        #expect(await runner.recordedCommands().count == 1)
    }

    @Test func concurrentCallsAreRecordedSafely() async throws {
        let runner = RecordingRunner(commandOutput: try Self.successOutput(TestFixtures.reportData()))
        let service = makeService(runner: runner)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await service.loadReport()
                }
            }
        }

        let commands = await runner.recordedCommands()
        #expect(commands.count == 8)
        #expect(commands.allSatisfy { $0.arguments == ["report", "--json"] })
    }


    @Test func cleanTimeoutExplainsPartialWork() async throws {
        let service = makeService(runner: TimeoutRunner(seconds: 180))

        do {
            _ = try await service.clean(ruleIDs: ["npm-cache"])
            Issue.record("Expected clean to throw")
        } catch let error as MKServiceError {
            #expect(error == .cleanTimedOut(seconds: 180))
            #expect(error.localizedDescription.contains("180"))
            #expect(error.localizedDescription.contains("may already be removed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func invalidJSONThrowsInvalidOutput() async throws {
        let runner = RecordingRunner(
            commandOutput: CommandOutput(status: 0, stdout: Data("not json".utf8), stderr: Data())
        )
        let service = makeService(runner: runner)

        do {
            _ = try await service.loadReport()
            Issue.record("Expected loadReport to throw")
        } catch let error as MKServiceError {
            guard case .invalidOutput = error else {
                Issue.record("Expected invalidOutput, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeService(runner: any CommandRunning) -> MKService {
        let locator = MKBinaries(
            environment: ["MK_BIN": mkPath, "PATH": "/usr/bin:/bin"],
            home: URL(fileURLWithPath: "/Users/tester"),
            isExecutable: { $0 == "/opt/test/bin/mk" }
        )
        return MKService(locator: locator, runner: runner)
    }

    private static func successOutput(_ data: Data) -> CommandOutput {
        CommandOutput(status: 0, stdout: data, stderr: Data())
    }
}

/// A runner that simulates the timeout path without launching a process.
actor TimeoutRunner: CommandRunning {
    private let seconds: TimeInterval

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    func run(_ command: Command) async throws -> CommandOutput {
        throw CommandError.timedOut(seconds: seconds)
    }
}

/// A lock-free fake: actor isolation serializes recording and reads.
actor RecordingRunner: CommandRunning {
    private let commandOutput: CommandOutput
    private var commands: [Command] = []

    init(commandOutput: CommandOutput) {
        self.commandOutput = commandOutput
    }

    func run(_ command: Command) async throws -> CommandOutput {
        commands.append(command)
        return commandOutput
    }

    func recordedCommands() -> [Command] {
        commands
    }
}

/// A thread-safe switch for the locator's executable predicate, so a test can
/// simulate `mk` being installed between two service calls.
final class MutableExecutableCheck: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private var allowed = false

    init(path: String) {
        self.path = path
    }

    func setAllowed(_ value: Bool) {
        lock.lock()
        allowed = value
        lock.unlock()
    }

    func isAllowed(_ candidate: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed && candidate == path
    }
}
