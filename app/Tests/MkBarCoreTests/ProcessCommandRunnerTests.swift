import Darwin
import Foundation
import Testing
@testable import MkBarCore

@Suite("Process command runner")
struct ProcessCommandRunnerTests {
    @Test func timesOutOnSlowCommand() async throws {
        let runner = ProcessCommandRunner()
        let started = Date()

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 0.2
                )
            )
            Issue.record("Expected the runner to time out")
        } catch let error as CommandError {
            guard case .timedOut(let seconds) = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
            #expect(abs(seconds - 0.2) < 0.0001)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(Date().timeIntervalSince(started) < 5.0)
    }

    @Test func capturesStdoutAndStatus() async throws {
        let runner = ProcessCommandRunner()

        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )

        #expect(output.status == 0)
        #expect(
            String(decoding: output.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "hello"
        )
        #expect(output.stderrText == "")
    }

    @Test func capturesStderrAndNonZeroStatus() async throws {
        let runner = ProcessCommandRunner()

        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf out; printf err >&2; exit 3"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )

        #expect(output.status == 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "out")
        #expect(output.stderrText == "err")
    }

    @Test func passesEnvironmentExactly() async throws {
        let runner = ProcessCommandRunner()

        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin", "MKBAR_TEST_VALUE": "two words"],
                timeout: 5
            )
        )

        #expect(output.status == 0)
        let lines = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .sorted()
        #expect(lines == ["MKBAR_TEST_VALUE=two words", "PATH=/usr/bin:/bin"])
    }

    @Test func nullStandardInputGivesImmediateEOF() async throws {
        let runner = ProcessCommandRunner()
        let started = Date()

        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: [:],
                timeout: 2
            )
        )

        #expect(output.status == 0)
        #expect(output.stdout.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func capturesOutputLargerThanAPipeBuffer() async throws {
        let runner = ProcessCommandRunner()

        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/usr/bin/head"),
                arguments: ["-c", "262144", "/dev/zero"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )

        #expect(output.status == 0)
        #expect(output.stdout.count == 262_144)
        #expect(output.stdout.allSatisfy { $0 == 0 })
        #expect(output.stderr.isEmpty)
    }

    @Test func launchFailureIncludesExecutablePath() async throws {
        let missing = "/nonexistent/mkbar-\(UUID().uuidString)"
        let runner = ProcessCommandRunner()

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: missing),
                    arguments: [],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 2
                )
            )
            Issue.record("Expected the runner to fail to launch")
        } catch let error as CommandError {
            guard case .launchFailed(let message) = error else {
                Issue.record("Expected launchFailed, got \(error)")
                return
            }
            #expect(message.contains(missing))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func timeoutReapsChildAndAllowsASecondRun() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessCommandRunner(temporaryRoot: root)
        let started = Date()

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 0.2
                )
            )
            Issue.record("Expected the runner to time out")
        } catch let error as CommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }

        // The child was terminated and reaped well before its own five-second
        // lifetime, and its scratch directory is gone.
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(entries(in: root).isEmpty)

        // A later run must still work on the same runner and root.
        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["still alive"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )
        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "still alive\n")
        #expect(entries(in: root).isEmpty)
    }

    @Test func escalatesToSIGKILLWhenTheChildIgnoresSIGTERM() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessCommandRunner(temporaryRoot: root, terminationGracePeriod: 0.1)
        let started = Date()

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 0.2
                )
            )
            Issue.record("Expected the runner to time out")
        } catch let error as CommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }

        // The ignored SIGTERM must not make the runner wait for the child's
        // own lifetime: 0.2s timeout + 0.1s grace, not 5s.
        #expect(Date().timeIntervalSince(started) < 2.0)
        #expect(entries(in: root).isEmpty)
    }

    @Test func timeoutKillsDescendantsInTheProcessGroup() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("grandchild")
        let runner = ProcessCommandRunner(temporaryRoot: root, terminationGracePeriod: 0.2)
        // Ignore SIGTERM in both the shell and the sleep it starts, so only a
        // process-group SIGKILL can end the tree.
        let script = "trap '' TERM; /bin/sleep 30 & echo $! > '\(pidFile.path)'; wait"

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 0.5
                )
            )
            Issue.record("Expected the runner to time out")
        } catch let error as CommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }

        let text = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        defer {
            _ = kill(pid, SIGKILL)
        }

        var gone = false
        for _ in 0..<60 {
            if kill(pid, 0) == -1 {
                gone = true
                break
            }
            usleep(50_000)
        }
        #expect(gone, "grandchild sleep survived the process-group timeout")
    }

    @Test func timeoutKillsHelperThatIgnoresTERMAfterLeaderExits() async throws {
        let root = try makeScratchRoot()
        let helperPIDFile = root.appendingPathComponent("helper.pid")
        var helperPID: pid_t?
        defer {
            if helperPID == nil,
               let text = try? String(contentsOf: helperPIDFile, encoding: .utf8) {
                helperPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let helperPID {
                _ = kill(helperPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }

        let runner = ProcessCommandRunner(
            temporaryRoot: root,
            terminationGracePeriod: 0.3
        )
        // The leader exits on SIGTERM. The helper ignores SIGTERM and records
        // its own pid, so the timeout must SIGKILL the surviving group member.
        let timeout: TimeInterval = 1.0
        let grace: TimeInterval = 0.3
        let started = Date()
        let script = """
        trap 'exit 0' TERM
        /bin/sh -c 'trap "" TERM; echo $$ > "\(helperPIDFile.path)"; while :; do /bin/sleep 1; done' &
        wait
        """

        let runTask = Task {
            try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: timeout
                )
            )
        }

        // Wait for the helper to be ready while the timeout clock is running,
        // so this test cannot pass merely because the helper never started.
        do {
            helperPID = try waitForPIDFile(helperPIDFile, timeout: 1.5)
        } catch {
            _ = try? await runTask.value
            throw error
        }

        do {
            _ = try await runTask.value
            Issue.record("Expected the runner to time out")
        } catch let error as CommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= timeout + 0.2, "grace period was skipped: \(elapsed)s")
        guard let helperPID else {
            Issue.record("Helper never wrote its pid file")
            return
        }

        var gone = false
        for _ in 0..<100 {
            if kill(helperPID, 0) == -1, errno == ESRCH {
                gone = true
                break
            }
            usleep(50_000)
        }
        #expect(gone, "helper survived the timeout after its leader exited")
    }

    @Test func timedOutChildIsNotLeftAsAZombie() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let runner = ProcessCommandRunner(temporaryRoot: root)
        let script = "echo $$ > '\(pidFile.path)'; exec /bin/sleep 5"

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script],
                    environment: ["PATH": "/usr/bin:/bin"],
                    timeout: 0.5
                )
            )
            Issue.record("Expected the runner to time out")
        } catch let error as CommandError {
            guard case .timedOut = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
        }

        let text = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        let probe = kill(pid, 0)
        let probeError = errno
        #expect(probe == -1)
        #expect(probeError == ESRCH)
    }

    @Test func cleansScratchDirectoryOnSuccessAndLaunchFailure() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessCommandRunner(temporaryRoot: root)

        let output = try await runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["ok"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )
        #expect(output.status == 0)
        #expect(entries(in: root).isEmpty)

        do {
            _ = try await runner.run(
                Command(
                    executable: URL(fileURLWithPath: "/nonexistent/mkbar"),
                    arguments: [],
                    environment: [:],
                    timeout: 2
                )
            )
            Issue.record("Expected the runner to fail to launch")
        } catch is CommandError {
            // Expected.
        }
        #expect(entries(in: root).isEmpty)
    }

    @Test func concurrentRunsRemainIndependent() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessCommandRunner(temporaryRoot: root)

        async let first = runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["first"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )
        async let second = runner.run(
            Command(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["second"],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 5
            )
        )

        let firstOutput = try await first
        let secondOutput = try await second
        let stdout = [firstOutput, secondOutput].map { String(decoding: $0.stdout, as: UTF8.self) }
        #expect(stdout == ["first\n", "second\n"])
        #expect(entries(in: root).isEmpty)
    }
}

private func waitForPIDFile(_ file: URL, timeout: TimeInterval = 2) throws -> pid_t {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        usleep(20_000)
    }
    throw NSError(
        domain: "ProcessCommandRunnerTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "helper pid file was not written"]
    )
}

private func makeScratchRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mkbar-runner-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func entries(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
}
