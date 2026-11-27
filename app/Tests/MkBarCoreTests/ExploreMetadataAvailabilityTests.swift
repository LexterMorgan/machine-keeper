import Foundation
import Testing
@testable import MkBarCore

@Suite("Explore metadata availability")
struct ExploreMetadataAvailabilityTests {
    @Test func scanRejectsAncestorWhenEitherFlagIsUnknown() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let ancestor = try fixture.directory("ordinary/ancestor")
        let root = try fixture.directory("ordinary/ancestor/child")
        try fixture.write("ordinary/ancestor/child/file.txt")
        let ancestorPath = ExplorePath.canonical(ancestor).path
        let live = ExploreDirectoryMetadata.live

        func service(hidden: Bool?, package: Bool?) -> ExploreService {
            ExploreService(home: fixture.home) { url in
                if ExplorePath.canonical(url).path == ancestorPath {
                    return ExploreDirectoryFlags(isHidden: hidden, isPackage: package)
                }
                return try live(url)
            }
        }

        for (hidden, package) in [(nil, false), (false, nil)] {
            do {
                _ = try await service(hidden: hidden, package: package).scan(
                    root: root,
                    policy: makeExplorePolicy()
                )
                Issue.record("Expected unknown metadata hidden=\(String(describing: hidden)) package=\(String(describing: package)) to reject the scan")
            } catch let error as ExploreError {
                guard case .rootMetadataUnavailable(let path) = error else {
                    Issue.record("Expected rootMetadataUnavailable, got \(error)")
                    continue
                }
                #expect(path == ancestorPath)
            } catch {
                Issue.record("Unexpected scan error: \(error)")
            }
        }

        let result = try await service(hidden: false, package: false).scan(
            root: root,
            policy: makeExplorePolicy()
        )
        #expect(result.files.map(\.url.lastPathComponent) == ["file.txt"])
    }

    @Test func traversalSkipsChildDirectoryWhenMetadataIsUnknown() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let root = try fixture.directory("root")
        let uncertain = try fixture.directory("root/uncertain")
        try fixture.write("root/uncertain/file.txt")
        try fixture.write("root/visible.txt")
        let uncertainPath = ExplorePath.canonical(uncertain).path
        let live = ExploreDirectoryMetadata.live

        let service = ExploreService(home: fixture.home) { url in
            if ExplorePath.canonical(url).path == uncertainPath {
                return ExploreDirectoryFlags(isHidden: nil, isPackage: false)
            }
            return try live(url)
        }

        let result = try await service.scan(
            root: root,
            policy: makeExplorePolicy()
        )

        #expect(result.files.map(\.url.lastPathComponent) == ["visible.txt"])
        #expect(result.skipped.contains {
            ExplorePath.canonical(URL(fileURLWithPath: $0.path)).path == uncertainPath
                && $0.reason.contains("metadata")
        })
    }

    @Test func trashSkipsParentWhenEitherFlagIsUnknown() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let file = try fixture.write("root/Visible/keep.txt")
        let scanned = try await ExploreService(home: fixture.home).scan(
            root: fixture.home.appendingPathComponent("root"),
            policy: makeExplorePolicy()
        )
        let selected = try #require(scanned.files.first)
        let parentPath = ExplorePath.canonical(file.deletingLastPathComponent()).path
        let live = ExploreDirectoryMetadata.live

        func service(hidden: Bool?, package: Bool?, recorder: TrashRecorder) -> ExploreTrashService {
            ExploreTrashService(
                home: fixture.home,
                policy: makeExplorePolicy(),
                metadataReader: { url in
                    if ExplorePath.canonical(url).path == parentPath {
                        return ExploreDirectoryFlags(isHidden: hidden, isPackage: package)
                    }
                    return try live(url)
                },
                trashOperation: { url in recorder.record(url) }
            )
        }

        for (hidden, package) in [(nil, false), (false, nil)] {
            let recorder = TrashRecorder()
            let results = await service(
                hidden: hidden,
                package: package,
                recorder: recorder
            ).trash(
                files: [selected],
                root: fixture.home.appendingPathComponent("root")
            )

            #expect(results.count == 1)
            #expect(results[0].outcome == .skipped)
            #expect(results[0].message.contains(parentPath))
            #expect(recorder.urls.isEmpty)
            #expect(fixture.exists(file))
        }

        let recorder = TrashRecorder()
        let results = await service(
            hidden: false,
            package: false,
            recorder: recorder
        ).trash(
            files: [selected],
            root: fixture.home.appendingPathComponent("root")
        )

        #expect(results.count == 1)
        #expect(results[0].outcome == .trashed)
        #expect(recorder.urls == [selected.url])
        // The injected operation records only; the file remains in place.
        #expect(fixture.exists(file))
    }
}
