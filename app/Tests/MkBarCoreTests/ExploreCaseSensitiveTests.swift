import Foundation
import Testing
@testable import MkBarCore

@Suite("Explore case-sensitive containment")
struct ExploreCaseSensitiveTests {
    @Test func caseSensitiveSiblingsStayOutsideTheSelectedFolder() async throws {
        let volume = try ExploreCaseSensitiveFixture()
        defer { volume.cleanup() }

        let home = volume.mount.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let selectedRoot = home.appendingPathComponent("Work", isDirectory: true)
        let siblingRoot = home.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: false)

        let selected = selectedRoot.appendingPathComponent("selected.txt")
        let sibling = siblingRoot.appendingPathComponent("sibling.txt")
        try Data("selected".utf8).write(to: selected)
        try Data("sibling".utf8).write(to: sibling)

        let service = ExploreService(home: home)
        let scan = try await service.scan(
            root: selectedRoot,
            policy: makeExplorePolicy()
        )
        #expect(scan.files.map(\.url.lastPathComponent) == ["selected.txt"])
        #expect(!ExplorePath.isWithin(sibling, root: selectedRoot))

        let snapshot = try FileMetadata.lstat(sibling)
        let crafted = ExploreFile(
            url: sibling,
            relativePath: "sibling.txt",
            homeRelativePath: ExplorePath.relativePath(of: sibling, in: home),
            size: snapshot.identity.size,
            modificationDate: snapshot.identity.modificationDate,
            identity: snapshot.identity,
            parentCanonicalPath: ExplorePath.canonical(siblingRoot).path,
            isProtected: false,
            protectionReason: nil
        )

        let recorder = TrashRecorder()
        let trash = ExploreTrashService(
            home: home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await trash.trash(files: [crafted], root: selectedRoot)

        #expect(results.count == 1)
        #expect(results[0].outcome == .skipped)
        #expect(recorder.urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }
}
