import Foundation
import Testing
@testable import MkBarCore
@testable import MkBar

@Suite("Explore model")
@MainActor
struct ExploreModelTests {
    @Test func folderSelectionScansAndStartsWithNothingSelected() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        try fixture.write("root/b.txt")

        let model = makeModel(fixture: fixture)
        model.selectFolder(fixture.home.appendingPathComponent("root"))
        await model.waitForScanToFinish()

        #expect(model.selectedFolder?.path == ExplorePath.canonical(
            fixture.home.appendingPathComponent("root")
        ).path)
        #expect(model.results.count == 2)
        #expect(model.selection.isEmpty)
        #expect(model.hasScanned)
        #expect(!model.canRequestTrash)
        #expect(model.trashDisabledReason?.contains("Select files") == true)
    }

    @Test func filterChangeClearsSelectionAndRescans() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        try fixture.write("root/b.pdf")

        let model = makeModel(fixture: fixture)
        model.selectFolder(fixture.home.appendingPathComponent("root"))
        await model.waitForScanToFinish()
        model.selectAll()
        #expect(model.selection.count == 2)

        model.setFilters(ExploreFilters(fileExtension: "txt"))
        #expect(model.selection.isEmpty)
        #expect(model.results.isEmpty)

        await model.waitForScanToFinish()
        #expect(model.results.map(\.url.lastPathComponent) == ["a.txt"])
        #expect(model.selection.isEmpty)
    }

    @Test func folderChangeClearsSelectionAndShowsOnlyTheNewFolder() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("first/a.txt")
        try fixture.write("second/b.txt")

        let model = makeModel(fixture: fixture)
        model.selectFolder(fixture.home.appendingPathComponent("first"))
        await model.waitForScanToFinish()
        model.selectAll()
        #expect(model.selection.count == 1)

        model.selectFolder(fixture.home.appendingPathComponent("second"))
        #expect(model.selection.isEmpty)
        await model.waitForScanToFinish()

        #expect(model.results.map(\.url.lastPathComponent) == ["b.txt"])
        #expect(model.selection.isEmpty)
    }

    @Test func staleScanResultsFromThePreviousFolderAreDiscarded() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        for index in 0..<40 {
            try fixture.write("slow/file-\(index).txt")
        }
        try fixture.write("fast/only.txt")

        let slowService = ExploreService(
            home: fixture.home,
            resultLimit: 500,
            scanObserver: { _ in
                Thread.sleep(forTimeInterval: 0.005)
            }
        )
        let model = makeModel(fixture: fixture, service: slowService)

        model.selectFolder(fixture.home.appendingPathComponent("slow"))
        model.selectFolder(fixture.home.appendingPathComponent("fast"))
        await model.waitForScanToFinish()

        #expect(model.results.map(\.url.lastPathComponent) == ["only.txt"])
        #expect(model.results.allSatisfy { $0.url.path.contains("/fast/") })
        #expect(model.selection.isEmpty)
    }

    @Test func trashRemovesOnlySuccessesAndRetainsFailuresAndSelection() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("root/a.txt")
        try fixture.write("root/b.txt")
        try fixture.write("root/fail.txt")

        let trashDirectory = fixture.container.appendingPathComponent("model-trash")
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let trashService = ExploreTrashService(
            home: fixture.home,
            policy: makeExplorePolicy(),
            trashOperation: { url in
                if url.lastPathComponent == "fail.txt" {
                    throw ModelTrashError.forced
                }
                try FileManager.default.moveItem(
                    at: url,
                    to: trashDirectory.appendingPathComponent(url.lastPathComponent)
                )
            }
        )

        let model = makeModel(fixture: fixture, trashService: trashService)
        model.selectFolder(fixture.home.appendingPathComponent("root"))
        await model.waitForScanToFinish()

        let a = try #require(model.results.first { $0.url.lastPathComponent == "a.txt" })
        let failing = try #require(model.results.first { $0.url.lastPathComponent == "fail.txt" })
        model.selection = [a.id, failing.id]

        model.requestTrash()
        #expect(model.isConfirmingTrash)
        #expect(model.pendingTrashFiles.count == 2)

        await model.confirmTrash()

        #expect(!model.isConfirmingTrash)
        #expect(model.pendingTrashFiles.isEmpty)
        #expect(model.results.map(\.url.lastPathComponent).sorted() == ["b.txt", "fail.txt"])
        #expect(model.selection == [failing.id])
        #expect(model.trashResults.count == 2)
        #expect(model.trashIssues.count == 1)
        #expect(model.trashIssues[0].url.lastPathComponent == "fail.txt")
        #expect(model.trashSummary?.contains("Moved 1 file (") == true)
        #expect(model.trashSummary?.contains(") to Trash.") == true)
        #expect(model.trashSummary?.contains("1 could not be moved") == true)
        #expect(!fixture.exists("root/a.txt"))
        #expect(fixture.exists("root/b.txt"))
        #expect(fixture.exists("root/fail.txt"))
    }

    @Test func protectedSelectionDisablesTrashWithExplanation() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Documents/private.txt")

        let model = makeModel(fixture: fixture)
        model.selectFolder(fixture.home.appendingPathComponent("Documents"))
        await model.waitForScanToFinish()
        model.selectAll()

        #expect(!model.canRequestTrash)
        #expect(model.trashDisabledReason?.contains("never-touch") == true)
        #expect(model.rootProtectionReason != nil)

        model.requestTrash()
        #expect(!model.isConfirmingTrash)
    }

    @Test func missingPolicyDisablesScanAndTrash() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        let model = ExploreModel(
            home: fixture.home,
            policy: nil,
            policyError: "policy.json is missing",
            debounce: .zero
        )

        #expect(!model.isPolicyLoaded)
        #expect(!model.canRequestTrash)
        #expect(model.trashDisabledReason?.contains("policy.json is missing") == true)

        model.selectFolder(fixture.home)
        #expect(model.folderError != nil)
        #expect(model.selectedFolder == nil)
    }

    private func makeModel(
        fixture: ExploreTempFixture,
        service: ExploreService? = nil,
        trashService: ExploreTrashService? = nil
    ) -> ExploreModel {
        let policy = makeExplorePolicy()
        let resolvedTrash = trashService ?? ExploreTrashService(
            home: fixture.home,
            policy: policy,
            trashOperation: { _ in
                Issue.record("The test unexpectedly used the Trash operation")
            }
        )
        return ExploreModel(
            home: fixture.home,
            policy: policy,
            service: service ?? ExploreService(home: fixture.home),
            trashService: resolvedTrash,
            debounce: .zero
        )
    }
}

private enum ModelTrashError: Error, LocalizedError {
    case forced

    var errorDescription: String? { "Simulated model Trash failure" }
}
