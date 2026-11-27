import Foundation
import Testing
@testable import MkBarCore

@Suite("Explore trash")
struct ExploreTrashTests {
    @Test func protectedNeverTouchFileIsSkippedWithReason() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Documents/private.txt")
        let files = try await scan(root: "Documents", fixture: fixture)
        #expect(files.count == 1)

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: files,
            root: fixture.home.appendingPathComponent("Documents")
        )

        #expect(results.count == 1)
        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("never-touch"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists("Documents/private.txt"))
    }

    @Test func libraryIsProtectedForTrashButStillInspectable() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Library/Caches/cache.bin")
        let files = try await scan(root: "Library", fixture: fixture)
        #expect(files.count == 1)
        #expect(files[0].isProtected)

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: files,
            root: fixture.home.appendingPathComponent("Library")
        )

        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("protected"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists("Library/Caches/cache.bin"))
    }

    @Test func replacedFileIsSkippedAndSurvives() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let fileURL = try fixture.write("root/change.txt", byteCount: 8)
        let files = try await scan(root: "root", fixture: fixture)
        let scanned = try #require(files.first)

        try Data(repeating: 0x42, count: 64).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: fileURL.path
        )

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: [scanned],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("changed"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists(fileURL))
    }

    @Test func mtimeOnlyChangeIsSkipped() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let fileURL = try fixture.write("root/touched.txt", byteCount: 8)
        let files = try await scan(root: "root", fixture: fixture)
        let scanned = try #require(files.first)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)],
            ofItemAtPath: fileURL.path
        )

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: [scanned],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results[0].outcome == .skipped)
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists(fileURL))
    }

    @Test func partialTrashFailureReportsEachOutcomeAndKeepsFailure() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        try fixture.write("root/fail.txt")
        try fixture.write("root/c.txt")
        let files = try await scan(root: "root", fixture: fixture)
        #expect(files.count == 3)

        let trashDirectory = fixture.container.appendingPathComponent("simulated-trash")
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)

        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in
                if url.lastPathComponent == "fail.txt" {
                    throw TrashTestError.forced
                }
                let destination = trashDirectory.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
            }
        )

        let results = await service.trash(
            files: files,
            root: fixture.home.appendingPathComponent("root")
        )

        let byName = Dictionary(uniqueKeysWithValues: results.map {
            ($0.url.lastPathComponent, $0)
        })
        #expect(byName.count == 3)
        #expect(byName["a.txt"]?.outcome == .trashed)
        #expect(byName["c.txt"]?.outcome == .trashed)
        #expect(byName["fail.txt"]?.outcome == .failed)
        #expect(byName["fail.txt"]?.message.contains("Simulated Trash failure") == true)
        #expect(byName["a.txt"]?.message == "Moved to Trash.")
        #expect(!fixture.exists("root/a.txt"))
        #expect(!fixture.exists("root/c.txt"))
        #expect(fixture.exists("root/fail.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trashDirectory.path).sorted() == ["a.txt", "c.txt"])
    }

    @Test func onlyTheSelectedFileIsPassedAndUnselectedFilesSurvive() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        try fixture.write("root/b.txt")
        try fixture.write("root/c.txt")
        let files = try await scan(root: "root", fixture: fixture)
        let selected = try #require(files.first { $0.url.lastPathComponent == "b.txt" })

        let trashDirectory = fixture.container.appendingPathComponent("selected-trash")
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)

        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in
                try FileManager.default.moveItem(
                    at: url,
                    to: trashDirectory.appendingPathComponent(url.lastPathComponent)
                )
            }
        )
        let results = await service.trash(
            files: [selected],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results.count == 1)
        #expect(results[0].outcome == .trashed)
        #expect(!fixture.exists("root/b.txt"))
        #expect(fixture.exists("root/a.txt"))
        #expect(fixture.exists("root/c.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trashDirectory.path) == ["b.txt"])
    }

    @Test func directoryCannotBeTrashed() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let directory = try fixture.directory("root/folder")
        let parent = directory.deletingLastPathComponent()
        let snapshot = try FileMetadata.lstat(directory)
        let crafted = ExploreFile(
            url: directory,
            relativePath: "folder",
            homeRelativePath: "folder",
            size: snapshot.identity.size,
            modificationDate: snapshot.identity.modificationDate,
            identity: snapshot.identity,
            parentCanonicalPath: ExplorePath.canonical(parent).path,
            isProtected: false,
            protectionReason: nil
        )

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: [crafted],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("Only files"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists("root/folder"))
    }

    @Test func finalSymlinkCannotBeTrashed() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/real.txt")
        let link = try fixture.symlink(
            "root/link.txt",
            to: fixture.home.appendingPathComponent("root/real.txt")
        )
        let snapshot = try FileMetadata.lstat(link)
        let crafted = ExploreFile(
            url: link,
            relativePath: "link.txt",
            homeRelativePath: "link.txt",
            size: snapshot.identity.size,
            modificationDate: snapshot.identity.modificationDate,
            identity: snapshot.identity,
            parentCanonicalPath: ExplorePath.canonical(link.deletingLastPathComponent()).path,
            isProtected: false,
            protectionReason: nil
        )

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: [crafted],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("symbolic link"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists("root/real.txt"))
        #expect(fixture.exists("root/link.txt"))
    }

    @Test func fileInsidePackageParentCannotBeTrashed() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let fileURL = try fixture.write("root/Thing.app/Contents/secret.txt", byteCount: 8)
        let parent = fileURL.deletingLastPathComponent()
        let snapshot = try FileMetadata.lstat(fileURL)
        let crafted = ExploreFile(
            url: fileURL,
            relativePath: "Thing.app/Contents/secret.txt",
            homeRelativePath: "root/Thing.app/Contents/secret.txt",
            size: snapshot.identity.size,
            modificationDate: snapshot.identity.modificationDate,
            identity: snapshot.identity,
            parentCanonicalPath: ExplorePath.canonical(parent).path,
            isProtected: false,
            protectionReason: nil
        )

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: [crafted],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("app bundle or package"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists(fileURL))
    }

    @Test func rootOutsideHomeSkipsEveryFile() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        let files = try await scan(root: "root", fixture: fixture)
        try FileManager.default.createDirectory(at: fixture.outside, withIntermediateDirectories: true)

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(files: files, root: fixture.outside)

        #expect(results[0].outcome == .skipped)
        #expect(results[0].message.contains("outside"))
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists("root/a.txt"))
    }

    @Test func movedParentIsSkipped() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        let files = try await scan(root: "root", fixture: fixture)
        try fixture.directory("moved")
        try FileManager.default.moveItem(
            at: fixture.home.appendingPathComponent("root/a.txt"),
            to: fixture.home.appendingPathComponent("moved/a.txt")
        )

        let recorder = TrashRecorder()
        let service = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in recorder.record(url) }
        )
        let results = await service.trash(
            files: files,
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results[0].outcome == .skipped)
        #expect(recorder.urls.isEmpty)
        #expect(fixture.exists("moved/a.txt"))
    }

    private func scan(
        root relativePath: String,
        fixture: ExploreTempFixture
    ) async throws -> [ExploreFile] {
        try await ExploreService(home: fixture.home).scan(
            root: fixture.home.appendingPathComponent(relativePath),
            policy: makeExplorePolicy()
        ).files
    }
}

private final class TrashRecorder: @unchecked Sendable {
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

private enum TrashTestError: Error, LocalizedError {
    case forced

    var errorDescription: String? {
        "Simulated Trash failure"
    }
}
