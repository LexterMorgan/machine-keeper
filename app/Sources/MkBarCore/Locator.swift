import Foundation

/// A resolved `mk` executable plus the environment its child process needs.
public struct MKBinary: Sendable {
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }
}

public enum LocatorError: Error, Sendable, Equatable, LocalizedError {
    case notFound
    case notExecutable(path: String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Could not find the mk executable."
        case .notExecutable(let path):
            return "The mk executable at \(path) is not executable."
        }
    }

    public var setupHint: String {
        "Install the CLI (`npm link` in the machine-keeper repo) or set MK_BIN to the mk executable."
    }
}

/// Finds the `mk` CLI the way a GUI app has to: explicitly, through PATH, and
/// through the directories installers commonly use on macOS.
///
/// `MK_BIN` semantics:
/// - Surrounding whitespace is ignored; an empty value falls through to PATH.
/// - A leading `~` or `~/` expands against the supplied home directory. `~user`
///   is not expanded.
/// - Relative paths are used as given. They resolve against the process's
///   current directory (for an app launched from Finder, `/`), so absolute
///   paths are strongly recommended. They are not rewritten here.
public struct MKBinaries: Sendable {
    private static let homeRelativeCandidates = [
        ".local/bin",
        "bin",
        ".npm-global/bin",
        ".volta/bin",
        ".bun/bin",
        ".cargo/bin",
        ".asdf/shims",
        ".local/share/pnpm",
        "Library/pnpm",
        ".local/share/mise/shims",
    ]

    private static let absoluteCandidates = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    /// A GUI app can inherit no PATH at all. `mk` still needs `du`, `df`,
    /// `vm_stat`, `sysctl`, and `osascript`, so keep the system directories
    /// reachable even then. They are appended last, so they never shadow a
    /// directory the user's shell already put ahead of them.
    private static let fallbackSystemDirectories = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private let environment: [String: String]
    private let home: URL
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            // `isExecutableFile` alone also returns true for directories,
            // because their execute bit permits traversal. A directory is not
            // a runnable `mk`, so reject it here instead of failing at launch.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return false
            }
            return FileManager.default.isExecutableFile(atPath: path)
        }
    ) {
        self.environment = environment
        self.home = home
        self.isExecutable = isExecutable
    }

    public func locate() throws -> MKBinary {
        if let raw = environment["MK_BIN"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let path = expandingTilde(in: trimmed)
                guard isExecutable(path) else {
                    throw LocatorError.notExecutable(path: path)
                }
                return makeBinary(at: path)
            }
        }

        for directory in inheritedPathDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("mk").path
            if isExecutable(candidate) {
                return makeBinary(at: candidate)
            }
        }

        for directory in candidateDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("mk").path
            if isExecutable(candidate) {
                return makeBinary(at: candidate)
            }
        }

        throw LocatorError.notFound
    }

    private var inheritedPathDirectories: [String] {
        (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private var candidateDirectories: [String] {
        Self.homeRelativeCandidates.map { home.appendingPathComponent($0).path }
            + Self.absoluteCandidates
    }

    private func expandingTilde(in raw: String) -> String {
        if raw == "~" {
            return home.path
        }
        guard raw.hasPrefix("~/") else {
            return raw
        }
        let suffix = String(raw.dropFirst(2))
        guard !suffix.isEmpty else {
            return home.path
        }
        return home.appendingPathComponent(suffix).path
    }

    private func makeBinary(at path: String) -> MKBinary {
        MKBinary(
            executable: URL(fileURLWithPath: path),
            environment: childEnvironment(resolvedPath: path)
        )
    }

    /// The GUI inherits a minimal PATH. Put the resolved directory first, then
    /// every known install location, then whatever PATH we inherited. This is
    /// what makes `#!/usr/bin/env node` work for an npm-installed `mk`.
    private func childEnvironment(resolvedPath: String) -> [String: String] {
        var child = environment
        var directories: [String] = []
        var seen = Set<String>()

        func add(_ directory: String) {
            guard !directory.isEmpty, seen.insert(directory).inserted else {
                return
            }
            directories.append(directory)
        }

        add(URL(fileURLWithPath: resolvedPath).deletingLastPathComponent().path)
        for directory in candidateDirectories {
            add(directory)
        }
        for directory in inheritedPathDirectories {
            add(directory)
        }
        for directory in Self.fallbackSystemDirectories {
            add(directory)
        }

        child["PATH"] = directories.joined(separator: ":")
        return child
    }
}
