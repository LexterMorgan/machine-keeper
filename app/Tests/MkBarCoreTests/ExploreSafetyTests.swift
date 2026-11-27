import Foundation
import Testing
@testable import MkBarCore

@Suite("Explore separation from cleanup")
struct ExploreSafetyTests {
    @Test func scannedFileIsNeverAReportRuleOrSafeRuleID() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Projects/random-cache.bin", byteCount: 512)
        let scan = try await ExploreService(home: fixture.home).scan(
            root: fixture.home,
            policy: makeExplorePolicy()
        )
        let scanned = try #require(scan.files.first)

        let report = Report(
            schemaVersion: 1,
            generatedAt: "2026-01-01T00:00:00.000Z",
            home: fixture.home.path,
            rows: [
                RuleRow(
                    id: "npm-cache",
                    title: "npm cache",
                    risk: "low",
                    optIn: false,
                    app: nil,
                    appRunning: false,
                    reclaim: "safe",
                    bytes: 1024,
                    files: 1
                )
            ]
        )
        let summary = report.summary()

        #expect(summary.safeRuleIDs == ["npm-cache"])
        #expect(!summary.safeRuleIDs.contains(scanned.url.path))
        #expect(!summary.safeRuleIDs.contains(scanned.relativePath))
        #expect(!summary.reclaimables.contains { $0.id == scanned.url.path })
        #expect(summary.reclaimables.map(\.id) == ["npm-cache"])
    }

    @Test func exploreDoesNotChangeTheRegistryProtectionList() async throws {
        let fixture = try ExploreTempFixture()
        defer { fixture.cleanup() }

        try fixture.write("Projects/keep.txt")
        let policy = makeExplorePolicy()
        let beforeNeverTouch = policy.neverTouch
        let beforeProtected = policy.exploreProtectedRoots

        _ = try await ExploreService(home: fixture.home).scan(
            root: fixture.home,
            policy: policy
        )

        #expect(policy.neverTouch == beforeNeverTouch)
        #expect(policy.exploreProtectedRoots == beforeProtected)
        #expect(policy.neverTouch.contains("Documents"))
    }
}
