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
