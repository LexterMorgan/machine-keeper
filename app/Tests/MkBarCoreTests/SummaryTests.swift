import Foundation
import Testing
import MkBarCore

@Suite("Report summary")
struct SummaryTests {
    @Test func defaultLimitKeepsTheThreeLargestButAllSafeIDs() {
        let report = Report(
            generatedAt: "2026-01-01T00:00:00.000Z",
            rows: [
                makeRow(id: "tiny", bytes: 1),
                makeRow(id: "large", bytes: 100),
                makeRow(id: "medium", bytes: 50),
                makeRow(id: "small", bytes: 10),
            ]
        )

        let summary = report.summary()
        #expect(summary.reclaimables.map(\.id) == ["large", "medium", "small"])
        #expect(summary.safeRuleIDs == ["large", "medium", "small", "tiny"])
    }

    @Test func negativeLimitReturnsNoReclaimablesButKeepsSafeIDs() {
        let report = Report(
            generatedAt: "2026-01-01T00:00:00.000Z",
            rows: [makeRow(id: "cache", bytes: 10)]
        )

        let summary = report.summary(top: -3)
        #expect(summary.reclaimables.isEmpty)
        #expect(summary.safeRuleIDs == ["cache"])
    }

    @Test func excludesOptInRunningAndEmptyRows() {
        let rows = [
            makeRow(id: "zero", bytes: 0),
            makeRow(id: "running", bytes: 500, app: "Spotify", appRunning: true),
            makeRow(id: "opt-in", bytes: 500, optIn: true),
            makeRow(id: "blocked-idle", bytes: 20, app: "Brave Browser", appRunning: false),
            makeRow(id: "a-tie", bytes: 100),
            makeRow(id: "b-tie", bytes: 100),
        ]
        let summary = Report(generatedAt: "2026-01-01T00:00:00.000Z", rows: rows).summary()

        #expect(summary.reclaimables.map(\.id) == ["a-tie", "b-tie", "blocked-idle"])
        #expect(summary.safeRuleIDs == ["a-tie", "b-tie", "blocked-idle"])
    }

    @Test func orphanCountSpansAllLaunchdCollections() {
        let startup = StartupInfo(
            userAgents: [
                makeEntry(label: "u.present", status: "present"),
                makeEntry(label: "u.missing", status: "missing"),
            ],
            systemAgents: [
                makeEntry(label: "s.missing", status: "missing"),
                makeEntry(label: "s.unknown", status: "unknown"),
            ],
            systemDaemons: [
                makeEntry(label: "d.missing", status: "missing"),
            ],
            loginItems: nil,
            brewServices: nil
        )
        let report = Report(
            generatedAt: "2026-01-01T00:00:00.000Z",
            rows: [],
            startup: startup
        )

        #expect(report.summary().orphanCount == 3)
    }

    @Test func emptyStartupHasNoOrphans() {
        let startup = StartupInfo(
            userAgents: [],
            systemAgents: [],
            systemDaemons: [],
            loginItems: [],
            brewServices: []
        )
        let report = Report(
            generatedAt: "2026-01-01T00:00:00.000Z",
            rows: [],
            startup: startup
        )

        #expect(report.summary().orphanCount == 0)
    }

    @Test func passesThroughMeasurementAndByteTotals() {
        let disk = DiskInfo(totalBytes: 100, usedBytes: 75, freeBytes: 25, percent: "75%")
        let memory = MemoryInfo(
            swap: SwapInfo(totalBytes: 10, usedBytes: 5, freeBytes: 5),
            pressureLevel: 2,
            pressureLabel: "warning",
            wiredBytes: 3,
            compressorBytes: 2,
            freeBytes: 4
        )
        let report = Report(
            generatedAt: "2026-01-01T00:00:00.000Z",
            disk: disk,
            memory: memory,
            rows: [makeRow(id: "cache", bytes: 10)],
            sweepableBytes: 10,
            blockedBytes: 20,
            optInBytes: 30
        )

        let summary = report.summary(top: 0)
        #expect(summary.disk == disk)
        #expect(summary.memory == memory)
        #expect(summary.sweepableBytes == 10)
        #expect(summary.blockedBytes == 20)
        #expect(summary.optInBytes == 30)
        #expect(summary.reclaimables.isEmpty)
    }

    private func makeRow(
        id: String,
        bytes: Int64,
        optIn: Bool = false,
        app: String? = nil,
        appRunning: Bool = false
    ) -> RuleRow {
        RuleRow(
            id: id,
            title: id,
            risk: optIn ? "user-files" : "rebuild",
            optIn: optIn,
            app: app,
            appRunning: appRunning,
            reclaim: "Test row.",
            bytes: bytes,
            files: 1
        )
    }

    private func makeEntry(label: String, status: String) -> StartupEntry {
        StartupEntry(
            label: label,
            file: "/Library/LaunchAgents/\(label).plist",
            program: status == "present" ? "/usr/bin/true" : nil,
            status: status
        )
    }
}
