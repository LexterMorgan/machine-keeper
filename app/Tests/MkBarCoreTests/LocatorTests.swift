import Foundation
import Testing
import MkBarCore

@Suite("Binary locator")
struct LocatorTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test func mkBinTakesPrecedenceOverPATH() throws {
        let locator = MKBinaries(
            environment: ["MK_BIN": "  /custom/tools/mk  ", "PATH": "/first/bin:/second/bin"],
            home: home,
            isExecutable: { $0 == "/custom/tools/mk" || $0 == "/first/bin/mk" }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/custom/tools/mk")

        let pathValue = try #require(binary.environment["PATH"])
        let firstPathEntry = try #require(pathValue.split(separator: ":").first)
        #expect(String(firstPathEntry) == "/custom/tools")
    }

    @Test func mkBinExpandsTilde() throws {
        let locator = MKBinaries(
            environment: ["MK_BIN": "~/tools/mk"],
            home: home,
            isExecutable: { $0 == "/Users/tester/tools/mk" }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/Users/tester/tools/mk")
    }

    @Test func emptyMKBinFallsThroughToPATH() throws {
        let locator = MKBinaries(
            environment: ["MK_BIN": "   ", "PATH": "/first/bin"],
            home: home,
            isExecutable: { $0 == "/first/bin/mk" }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/first/bin/mk")
    }

    @Test func pathOrderIsRespected() throws {
        let locator = MKBinaries(
            environment: ["PATH": "/first/bin:/second/bin"],
            home: home,
            isExecutable: { $0 == "/first/bin/mk" || $0 == "/second/bin/mk" }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/first/bin/mk")

        let pathEntries = try #require(binary.environment["PATH"]).split(separator: ":").map(String.init)
        #expect(pathEntries.first == "/first/bin")
        #expect(pathEntries.contains("/second/bin"))
    }

    @Test func candidateDirectoryIsFoundWhenPATHIsEmpty() throws {
        let resolved = "/Users/tester/.npm-global/bin/mk"
        let locator = MKBinaries(
            environment: [:],
            home: home,
            isExecutable: { $0 == resolved }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == resolved)

        let pathEntries = try #require(binary.environment["PATH"]).split(separator: ":").map(String.init)
        #expect(pathEntries.first == "/Users/tester/.npm-global/bin")
        #expect(pathEntries.contains("/Users/tester/.local/bin"))
        #expect(pathEntries.contains("/opt/homebrew/bin"))
        #expect(pathEntries.contains("/usr/local/bin"))
        #expect(pathEntries.contains("/opt/local/bin"))
        #expect(pathEntries.contains("/usr/bin"))
        #expect(pathEntries.contains("/bin"))
        #expect(pathEntries.contains("/usr/sbin"))
        #expect(pathEntries.contains("/sbin"))
        #expect(Set(pathEntries).count == pathEntries.count)
    }

    @Test func mkBinMustBeExecutable() {
        let locator = MKBinaries(
            environment: ["MK_BIN": "/blocked/mk", "PATH": "/first/bin"],
            home: home,
            isExecutable: { $0 == "/first/bin/mk" }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch let error as LocatorError {
            #expect(error == .notExecutable(path: "/blocked/mk"))
            #expect(
                error.setupHint
                    == "Install the CLI (`npm link` in the machine-keeper repo) or set MK_BIN to the mk executable."
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func defaultCheckRejectsADirectorySetAsMKBin() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // `isExecutableFile` alone returns true for traversable directories,
        // but a directory cannot be launched as `mk`.
        let locator = MKBinaries(environment: ["MK_BIN": directory.path])

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch let error as LocatorError {
            #expect(error == .notExecutable(path: directory.path))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func defaultCheckRejectsANonExecutableFile() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mk")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let locator = MKBinaries(environment: ["MK_BIN": file.path])

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch let error as LocatorError {
            #expect(error == .notExecutable(path: file.path))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func defaultCheckAcceptsAnExecutableFile() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mk")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let locator = MKBinaries(environment: ["MK_BIN": file.path])
        let binary = try locator.locate()

        #expect(binary.executable.path == file.path)
        let pathValue = try #require(binary.environment["PATH"])
        let first = try #require(pathValue.split(separator: ":").first)
        #expect(String(first) == directory.path)
    }

    @Test func relativeMKBinIsResolvedAgainstTheWorkingDirectory() throws {
        // Documented behavior: a relative MK_BIN is not rewritten. The modify
        // check sees the path as written, and the executable URL resolves it
        // against the process's working directory.
        let raw = "relative-tools/mk"
        let locator = MKBinaries(
            environment: ["MK_BIN": raw, "PATH": "/usr/bin:/bin"],
            home: home,
            isExecutable: { $0 == raw }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == URL(fileURLWithPath: raw).path)
        let pathValue = try #require(binary.environment["PATH"])
        let first = try #require(pathValue.split(separator: ":").first)
        #expect(String(first) == URL(fileURLWithPath: raw).deletingLastPathComponent().path)
    }

    @Test func pathWinsOverInstallCandidates() throws {
        let candidate = "/Users/tester/.local/bin/mk"
        let locator = MKBinaries(
            environment: ["PATH": "/first/bin"],
            home: home,
            isExecutable: { $0 == "/first/bin/mk" || $0 == candidate }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/first/bin/mk")
    }

    @Test func mkBinWinsOverInstallCandidates() throws {
        let candidate = "/Users/tester/.local/bin/mk"
        let locator = MKBinaries(
            environment: ["MK_BIN": "/custom/tools/mk"],
            home: home,
            isExecutable: { $0 == "/custom/tools/mk" || $0 == candidate }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/custom/tools/mk")
    }

    @Test func childPATHDedupesAndOrdersCandidatesBeforeInheritedPATH() throws {
        let locator = MKBinaries(
            environment: [
                "MK_BIN": "/custom/tools/mk",
                "PATH": "/custom/tools:/usr/bin:/bin:/usr/bin",
            ],
            home: home,
            isExecutable: { $0 == "/custom/tools/mk" }
        )

        let entries = try #require(locator.locate().environment["PATH"])
            .split(separator: ":")
            .map(String.init)

        #expect(entries.first == "/custom/tools")
        #expect(entries.contains("/Users/tester/.local/bin"))
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(Set(entries).count == entries.count)
        #expect(entries.filter { $0 == "/custom/tools" }.count == 1)
        #expect(entries.filter { $0 == "/usr/bin" }.count == 1)
        #expect(entries.filter { $0 == "/bin" }.count == 1)

        let candidateIndex = try #require(entries.firstIndex(of: "/opt/homebrew/bin"))
        let inheritedIndex = try #require(entries.firstIndex(of: "/usr/bin"))
        #expect(candidateIndex < inheritedIndex)
    }

    @Test func emptyPATHSegmentsAreIgnored() throws {
        let locator = MKBinaries(
            environment: ["PATH": ":/first/bin::/second/bin:"],
            home: home,
            isExecutable: { $0 == "/first/bin/mk" }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/first/bin/mk")

        let entries = try #require(binary.environment["PATH"])
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(!entries.contains(""))
        #expect(entries.first == "/first/bin")
    }

    @Test func childPATHFallsBackToSystemDirectories() throws {
        let resolved = "/Users/tester/.local/bin/mk"
        let locator = MKBinaries(
            environment: [:],
            home: home,
            isExecutable: { $0 == resolved }
        )

        let entries = try #require(locator.locate().environment["PATH"])
            .split(separator: ":")
            .map(String.init)

        #expect(entries.first == "/Users/tester/.local/bin")
        #expect(Array(entries.suffix(4)) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(Set(entries).count == entries.count)
    }

    @Test func bundledCLIUsesNodeAndPrefixesTheScript() throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("cli", isDirectory: true)
        let script = cli.appendingPathComponent("bin/mk.mjs").path

        let locator = MKBinaries(
            environment: ["MK_NODE": "/custom/node"],
            home: home,
            isExecutable: { $0 == "/custom/node" },
            bundledCLIDirectory: cli,
            isReadable: { $0 == script }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/custom/node")
        #expect(binary.argumentsPrefix == [script])
    }

    @Test func mkBinStillBeatsTheBundledCLI() throws {
        let cli = URL(fileURLWithPath: "/tmp/cli", isDirectory: true)
        let script = cli.appendingPathComponent("bin/mk.mjs").path
        let locator = MKBinaries(
            environment: ["MK_BIN": "/custom/mk", "MK_NODE": "/custom/node"],
            home: home,
            isExecutable: { $0 == "/custom/mk" || $0 == "/custom/node" },
            bundledCLIDirectory: cli,
            isReadable: { $0 == script }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/custom/mk")
        #expect(binary.argumentsPrefix.isEmpty)
    }

    @Test func bundledCLIFallsBackToInstalledMKWhenNodeIsMissing() throws {
        let cli = URL(fileURLWithPath: "/tmp/cli", isDirectory: true)
        let script = cli.appendingPathComponent("bin/mk.mjs").path
        let locator = MKBinaries(
            environment: ["PATH": "/first/bin"],
            home: home,
            isExecutable: { $0 == "/first/bin/mk" },
            bundledCLIDirectory: cli,
            isReadable: { $0 == script }
        )

        let binary = try locator.locate()
        #expect(binary.executable.path == "/first/bin/mk")
        #expect(binary.argumentsPrefix.isEmpty)
    }

    @Test func bundledCLIWithoutNodeOrInstalledMKExplainsTheNodeRequirement() {
        let cli = URL(fileURLWithPath: "/tmp/cli", isDirectory: true)
        let script = cli.appendingPathComponent("bin/mk.mjs").path
        let locator = MKBinaries(
            environment: [:],
            home: home,
            isExecutable: { _ in false },
            bundledCLIDirectory: cli,
            isReadable: { $0 == script }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch let error as LocatorError {
            #expect(error == .nodeNotFound)
            #expect(error.setupHint.contains("Node.js"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func mkNodeMustBeExecutable() {
        let cli = URL(fileURLWithPath: "/tmp/cli", isDirectory: true)
        let script = cli.appendingPathComponent("bin/mk.mjs").path
        let locator = MKBinaries(
            environment: ["MK_NODE": "/blocked/node"],
            home: home,
            isExecutable: { _ in false },
            bundledCLIDirectory: cli,
            isReadable: { $0 == script }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch let error as LocatorError {
            #expect(error == .nodeNotExecutable(path: "/blocked/node"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func notFoundThrows() {
        let locator = MKBinaries(
            environment: ["PATH": "/first/bin:/second/bin"],
            home: home,
            isExecutable: { _ in false }
        )

        do {
            _ = try locator.locate()
            Issue.record("Expected locate() to throw")
        } catch let error as LocatorError {
            #expect(error == .notFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func makeScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mkbar-locator-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
