import Foundation
@testable import MkBarCore

/// A disposable folder tree for Explore tests. Every path lives under the
/// system temporary directory; no test reads or writes the real home.
struct ExploreTempFixture {
    let container: URL
    let home: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkbar-explore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        container = base
        home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    var canonicalHome: URL {
        ExplorePath.canonical(home)
    }

    var outside: URL {
        container.appendingPathComponent("outside", isDirectory: true)
    }

    @discardableResult
    func write(
        _ relativePath: String,
        byteCount: Int = 8,
        modified: Date? = nil
    ) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @discardableResult
    func symlink(_ relativePath: String, to destination: URL) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relativePath).path)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Set Finder's hidden flag without renaming the folder. URLResourceValues
    /// writes the FinderInfo attribute used by Finder for hidden items.
    func setFinderHidden(_ url: URL, _ hidden: Bool = true) throws {
        var values = URLResourceValues()
        values.isHidden = hidden
        var target = url
        try target.setResourceValues(values)
    }

    func cleanup() {
        // A test may have removed read permission to exercise skipped
        // locations. Restore traversal before deleting the disposable tree.
        if let enumerator = FileManager.default.enumerator(
            at: container,
            includingPropertiesForKeys: nil
        ) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
            }
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: container.path
        )
        try? FileManager.default.removeItem(at: container)
    }
}

func makeExplorePolicy(
    neverTouch: [String] = ["Documents", ".ssh"],
    protectedRoots: [String] = ["Library"]
) -> ProtectionPolicy {
    ProtectionPolicy(neverTouch: neverTouch, exploreProtectedRoots: protectedRoots)
}

func temporaryExplorePolicyFile(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mkbar-policy-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    return url
}


/// A disposable case-sensitive APFS volume for containment tests. The normal
/// macOS volume is usually case-insensitive, so a real sibling pair such as
/// Work/work can only be created on a case-sensitive filesystem. hdiutil is
/// available on macOS command-line tool installs and CI macOS runners; if it
/// cannot create/mount the image, the test fails with the tool's output rather
/// than silently claiming coverage.
struct ExploreCaseSensitiveFixture {
    let container: URL
    let mount: URL
    let image: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkbar-explore-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        container = base
        mount = base.appendingPathComponent("volume", isDirectory: true)
        image = base.appendingPathComponent("case-sensitive.dmg", isDirectory: false)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)

        let create = try Self.run(
            "/usr/bin/hdiutil",
            [
                "create", "-size", "64m", "-fs", "Case-sensitive APFS",
                "-volname", "MKExploreCase-\(UUID().uuidString.prefix(8))",
                image.path,
            ]
        )
        guard create.code == 0 else {
            throw Self.failure("hdiutil create", create.output)
        }

        let attach = try Self.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-noverify", "-mountpoint", mount.path, image.path]
        )
        guard attach.code == 0 else {
            throw Self.failure("hdiutil attach", attach.output)
        }
    }

    func cleanup() {
        _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try? FileManager.default.removeItem(at: container)
    }

    private struct ToolResult {
        let code: Int32
        let output: String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ToolResult(
            code: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private static func failure(_ operation: String, _ output: String) -> Error {
        NSError(
            domain: "ExploreCaseSensitiveFixture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(output)"]
        )
    }
}


final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }
}
