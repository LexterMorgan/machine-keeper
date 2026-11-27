import Foundation
import Testing
@testable import MkBarCore

@Suite("Explore scan")
struct ExploreScanTests {
    @Test func filtersCombineWithAndAndExtensionIsCaseInsensitive() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let old = Date(timeIntervalSince1970: 1_700_000_000)

        try fixture.write("root/Report-Final.TXT", byteCount: 2048, modified: recent)
        try fixture.write("root/report-small.txt", byteCount: 100, modified: recent)
        try fixture.write("root/notes-report.txt", byteCount: 2048, modified: old)
        try fixture.write("root/report.pdf", byteCount: 2048, modified: recent)
        try fixture.write("root/unrelated.txt", byteCount: 2048, modified: recent)

        let service = ExploreService(home: fixture.home)
        let result = try await service.scan(
            root: fixture.home.appendingPathComponent("root"),
            filters: ExploreFilters(
                filenameContains: "report",
                fileExtension: ".TXT",
                minimumSizeBytes: 1024,
                modifiedAfter: Date(timeIntervalSince1970: 1_750_000_000)
            ),
            policy: makeExplorePolicy()
        )

        #expect(result.files.map(\.url.lastPathComponent) == ["Report-Final.TXT"])
        #expect(!result.isTruncated)
        #expect(!result.isCancelled)

        let noMatch = try await service.scan(
            root: fixture.home.appendingPathComponent("root"),
            filters: ExploreFilters(filenameContains: "no-such-name"),
            policy: makeExplorePolicy()
        )
        #expect(noMatch.files.isEmpty)
    }

    @Test func scanSkipsSymlinksHiddenEntriesAndAppBundles() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let visible = try fixture.write("root/visible.txt")
        try fixture.write("root/.hidden.txt")
        try fixture.write("root/.hiddenDir/secret.txt")
        try fixture.write("root/App.app/Contents/secret.txt")
        try fixture.write("root/Bundle.bundle/secret.txt")
        try fixture.write("root/Framework.framework/secret.txt")
        try fixture.write("root/realDir/inner.txt")
        try fixture.symlink("root/link.txt", to: visible)
        try fixture.symlink("root/linkDir", to: fixture.home.appendingPathComponent("root/realDir"))

        let result = try await ExploreService(home: fixture.home).scan(
            root: fixture.home.appendingPathComponent("root"),
            policy: makeExplorePolicy()
        )

        let names = Set(result.files.map(\.url.lastPathComponent))
        #expect(names == ["visible.txt", "inner.txt"])
        #expect(result.files.allSatisfy { $0.url.path.hasPrefix(fixture.canonicalHome.path) })
        #expect(result.files.first { $0.url.lastPathComponent == "inner.txt" }?.relativePath == "realDir/inner.txt")

        let reasons = result.skipped.map(\.reason)
        #expect(reasons.contains("Hidden"))
        #expect(reasons.contains("Symbolic link"))
        #expect(reasons.contains("App bundle or package"))
        #expect(!result.files.contains { $0.url.lastPathComponent == "secret.txt" })
    }

    @Test func symlinkedParentIntoProtectedIsInspectedAndProtected() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Documents/private.txt")
        try fixture.symlink("alias", to: fixture.home.appendingPathComponent("Documents"))

        let result = try await ExploreService(home: fixture.home).scan(
            root: fixture.home.appendingPathComponent("alias"),
            policy: makeExplorePolicy()
        )

        #expect(result.root.path == ExplorePath.canonical(fixture.home.appendingPathComponent("Documents")).path)
        #expect(result.files.count == 1)
        #expect(result.files[0].isProtected)
        #expect(result.files[0].protectionReason?.contains("never-touch") == true)
    }

    @Test func symlinkedParentOutsideHomeIsRejected() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try FileManager.default.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: fixture.outside.appendingPathComponent("secret.txt"))
        try fixture.symlink("outsideLink", to: fixture.outside)

        let service = ExploreService(home: fixture.home)
        do {
            _ = try await service.scan(
                root: fixture.home.appendingPathComponent("outsideLink"),
                policy: makeExplorePolicy()
            )
            Issue.record("Expected a symlinked root outside home to be rejected")
        } catch let error as ExploreError {
            guard case .rootOutsideHome = error else {
                Issue.record("Expected rootOutsideHome, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let homeScan = try await service.scan(root: fixture.home, policy: makeExplorePolicy())
        #expect(!homeScan.files.contains { $0.url.lastPathComponent == "secret.txt" })
        #expect(homeScan.skipped.contains { $0.reason == "Symbolic link" })
    }

    @Test func protectedFilesRemainInspectableButProtected() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Documents/doc.txt")
        try fixture.write("Library/Caches/cache.bin")
        try fixture.write("Projects/keep.txt")

        let result = try await ExploreService(home: fixture.home).scan(
            root: fixture.home,
            policy: makeExplorePolicy()
        )

        let byName = Dictionary(uniqueKeysWithValues: result.files.map {
            ($0.url.lastPathComponent, $0)
        })
        #expect(byName.count == 3)
        #expect(byName["doc.txt"]?.isProtected == true)
        #expect(byName["cache.bin"]?.isProtected == true)
        #expect(byName["keep.txt"]?.isProtected == false)
        #expect(byName["doc.txt"]?.protectionReason?.contains("never-touch") == true)
        #expect(byName["cache.bin"]?.protectionReason?.contains("protected in Explore") == true)
    }

    @Test func rootOutsideHomeAndNonDirectoryRootAreRejected() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try FileManager.default.createDirectory(at: fixture.outside, withIntermediateDirectories: true)
        let service = ExploreService(home: fixture.home)

        do {
            _ = try await service.scan(root: fixture.outside, policy: makeExplorePolicy())
            Issue.record("Expected a root outside home to be rejected")
        } catch let error as ExploreError {
            guard case .rootOutsideHome = error else {
                Issue.record("Expected rootOutsideHome, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let file = try fixture.write("not-a-folder.txt")
        do {
            _ = try await service.scan(root: file, policy: makeExplorePolicy())
            Issue.record("Expected a file root to be rejected")
        } catch let error as ExploreError {
            guard case .rootNotDirectory = error else {
                Issue.record("Expected rootNotDirectory, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let homeResult = try await service.scan(root: fixture.home, policy: makeExplorePolicy())
        #expect(homeResult.files.contains { $0.url.lastPathComponent == "not-a-folder.txt" })
    }

    @Test func capIsBoundedAndTruncationIsProven() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        try fixture.write("root/b.txt")
        try fixture.write("root/c.txt")

        let service = ExploreService(home: fixture.home, resultLimit: 2)
        let capped = try await service.scan(
            root: fixture.home.appendingPathComponent("root"),
            policy: makeExplorePolicy()
        )
        #expect(capped.files.count == 2)
        #expect(capped.isTruncated)
        #expect(capped.resultLimit == 2)

        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("root/c.txt"))
        let exact = try await service.scan(
            root: fixture.home.appendingPathComponent("root"),
            policy: makeExplorePolicy()
        )
        #expect(exact.files.count == 2)
        #expect(!exact.isTruncated)
    }

    @Test func taskCancellationStopsTheWalkWithPartialResults() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        for index in 0..<8 {
            try fixture.write("root/file-\(index).txt")
        }

        let service = ExploreService(home: fixture.home, resultLimit: 100) { count in
            if count == 2 {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        }

        let result = try await service.scan(
            root: fixture.home.appendingPathComponent("root"),
            policy: makeExplorePolicy()
        )

        #expect(result.isCancelled)
        #expect(result.files.count == 2)
    }

    @Test func hiddenAndPackageRootsAreRejectedBeforeEnumeration() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let hiddenRoot = try fixture.directory("HiddenRoot")
        try fixture.write("HiddenRoot/file.txt")
        try fixture.setFinderHidden(hiddenRoot)

        let hiddenParent = try fixture.directory("HiddenParent")
        let hiddenChild = try fixture.directory("HiddenParent/child")
        try fixture.write("HiddenParent/child/file.txt")
        try fixture.setFinderHidden(hiddenParent)

        let packageRoot = try fixture.directory("Thing.app")
        try fixture.write("Thing.app/file.txt")
        let packageChild = try fixture.directory("Bundle.app/Contents")
        try fixture.write("Bundle.app/Contents/file.txt")

        let service = ExploreService(home: fixture.home)
        let cases: [(URL, (ExploreError) -> Bool, String)] = [
            (hiddenRoot, { if case .rootHidden = $0 { return true }; return false }, "hidden root"),
            (hiddenChild, { if case .rootInHidden = $0 { return true }; return false }, "inside hidden"),
            (packageRoot, { if case .rootPackage = $0 { return true }; return false }, "package root"),
            (packageChild, { if case .rootInPackage = $0 { return true }; return false }, "inside package"),
        ]

        for (root, matches, label) in cases {
            do {
                _ = try await service.scan(root: root, policy: makeExplorePolicy())
                Issue.record("Expected \(label) to be rejected before scanning")
            } catch let error as ExploreError {
                #expect(matches(error), "unexpected error for \(label): \(error)")
            } catch {
                Issue.record("Unexpected error for \(label): \(error)")
            }
        }

        try fixture.write("Documents/ordinary.txt")
        let documents = try await service.scan(
            root: fixture.home,
            policy: makeExplorePolicy()
        )
        let doc = try #require(documents.files.first {
            $0.url.lastPathComponent == "ordinary.txt"
        })
        #expect(doc.isProtected)
        #expect(doc.protectionReason?.contains("never-touch") == true)
    }

    @Test func unreadableLocationsAreReportedNotReturned() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/visible.txt")
        try fixture.write("root/locked.txt")
        try fixture.write("root/lockedDir/inside.txt")

        let lockedDirectory = fixture.home.appendingPathComponent("root/lockedDir")
        let lockedFile = fixture.home.appendingPathComponent("root/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedFile.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: lockedDirectory.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: lockedFile.path
            )
        }

        let result = try await ExploreService(home: fixture.home).scan(
            root: fixture.home.appendingPathComponent("root"),
            policy: makeExplorePolicy()
        )

        #expect(result.files.map(\.url.lastPathComponent) == ["visible.txt"])
        #expect(result.skipped.contains { $0.path.hasSuffix("lockedDir") })
        #expect(result.skipped.contains { $0.path.hasSuffix("locked.txt") })
        #expect(!result.files.contains { $0.url.lastPathComponent == "inside.txt" })
    }
}
