import Foundation
import Testing
import MkBarCore

@Suite("Report models")
struct ModelsTests {
    @Test func fixtureReportDecodesExpectedValues() throws {
        let report = try JSONDecoder().decode(Report.self, from: TestFixtures.reportData())

        #expect(report.schemaVersion == 1)
        #expect(report.generatedAt == "2026-11-25T14:38:00.704Z")
        #expect(report.home == "/Users/tester")
        #expect(report.rows.count == 5)
        #expect(report.optInRows.count == 1)
        #expect(report.sweepableBytes == 603_516_928)
        #expect(report.blockedBytes == 8_823_283_712)
        #expect(report.optInBytes == 147_955_712)

        let disk = try #require(report.disk)
        #expect(disk.totalBytes == 245_107_195_904)
        #expect(disk.usedBytes == 147_955_281_920)
        #expect(disk.freeBytes == 52_048_601_088)
        #expect(disk.percent == "74%")

        let memory = try #require(report.memory)
        #expect(memory.pressureLevel == 2)
        #expect(memory.pressureLabel == "warning")
        #expect(memory.swap.totalBytes == 4_294_967_296)
        #expect(memory.swap.usedBytes == 2_589_657_661)
        #expect(memory.wiredBytes == 1_508_081_664)
        #expect(memory.compressorBytes == 3_024_879_616)
        #expect(memory.freeBytes == 59_850_752)
        #expect(memory.totalBytes == 8_589_934_592)
        #expect(memory.usedBytes == 5_998_149_632)
        #expect(memory.appBytes == 1_465_188_352)
        #expect(memory.cachedBytes == 890_224_640)

        let npm = try #require(report.rows.first { $0.id == "npm-cache" })
        #expect(npm.title == "npm cache")
        #expect(npm.risk == "rebuild")
        #expect(npm.optIn == false)
        #expect(npm.app == nil)
        #expect(npm.appRunning == false)
        #expect(npm.reclaim == "Packages are re-downloaded on demand.")
        #expect(npm.bytes == 297_222_144)
        #expect(npm.files == 1)

        let spotify = try #require(report.rows.first { $0.id == "spotify-cache" })
        #expect(spotify.app == "Spotify")
        #expect(spotify.appRunning)

        let startup = try #require(report.startup)
        #expect(startup.userAgents.count == 3)
        #expect(startup.systemAgents.count == 1)
        #expect(startup.systemDaemons.count == 1)
        #expect(startup.userAgents.filter(\.isOrphan).map(\.label) == ["com.lwouis.alt-tab-macos"])
        #expect(startup.systemAgents.filter(\.isOrphan).isEmpty)
        #expect(startup.systemDaemons.filter(\.isOrphan).isEmpty)
        #expect(startup.loginItems == nil)
        #expect(startup.brewServices == nil)
    }

    @Test func memoryDecodesLegacyPayloadWithoutRAMCounters() throws {
        let json = #"""
        {
          "generatedAt": "2026-01-01T00:00:00.000Z",
          "rows": [],
          "memory": {
            "swap": { "totalBytes": 1, "usedBytes": 0, "freeBytes": 1 },
            "pressureLevel": 1,
            "pressureLabel": "normal",
            "wiredBytes": 1,
            "compressorBytes": 2,
            "freeBytes": 3
          }
        }
        """#
        let report = try JSONDecoder().decode(Report.self, from: Data(json.utf8))
        #expect(report.memory?.totalBytes == nil)
        #expect(report.memory?.usedBytes == nil)
        #expect(report.memory?.appBytes == nil)
        #expect(report.memory?.cachedBytes == nil)
        #expect(report.memory?.wiredBytes == 1)
    }

    @Test func reportDecodesMinimalPayloadWithDefaults() throws {
        let json = #"{"generatedAt":"2026-01-01T00:00:00.000Z","rows":[]}"#
        let report = try JSONDecoder().decode(Report.self, from: Data(json.utf8))

        #expect(report.schemaVersion == nil)
        #expect(report.generatedAt == "2026-01-01T00:00:00.000Z")
        #expect(report.home == nil)
        #expect(report.disk == nil)
        #expect(report.memory == nil)
        #expect(report.rows.isEmpty)
        #expect(report.optInRows.isEmpty)
        #expect(report.sweepableBytes == 0)
        #expect(report.blockedBytes == 0)
        #expect(report.optInBytes == 0)
        #expect(report.startup == nil)
    }

    @Test func reportRequiresGeneratedAtAndRows() {
        let missingRows = Data(#"{"generatedAt":"2026-01-01T00:00:00.000Z"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Report.self, from: missingRows)
        }

        let missingGeneratedAt = Data(#"{"rows":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Report.self, from: missingGeneratedAt)
        }
    }

    @Test func reportToleratesNullSectionsUnknownKeysAndMissingOptionals() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-01-01T00:00:00.000Z",
          "home": "/Users/tester",
          "futureTopLevel": {"anything": [1, true]},
          "disk": null,
          "memory": null,
          "rows": [
            {
              "id": "cached-thing",
              "title": "Cached thing",
              "risk": "rebuild",
              "optIn": false,
              "appRunning": false,
              "reclaim": "",
              "bytes": 10,
              "files": 1,
              "futureRowField": "ignored"
            }
          ],
          "optInRows": [],
          "sweepableBytes": 10,
          "blockedBytes": 0,
          "optInBytes": 0,
          "startup": {
            "userAgents": [
              {
                "label": "com.example.agent",
                "file": "/Users/tester/Library/LaunchAgents/com.example.agent.plist",
                "status": "present",
                "futureEntryField": 1
              }
            ],
            "systemAgents": [],
            "systemDaemons": [],
            "loginItems": null,
            "brewServices": null,
            "futureStartupField": true
          }
        }
        """
        let report = try JSONDecoder().decode(Report.self, from: Data(json.utf8))

        #expect(report.schemaVersion == 1)
        #expect(report.home == "/Users/tester")
        #expect(report.disk == nil)
        #expect(report.memory == nil)
        #expect(report.rows.count == 1)
        #expect(report.rows[0].app == nil)
        #expect(report.rows[0].reclaim == "")
        #expect(report.rows[0].bytes == 10)

        let startup = try #require(report.startup)
        #expect(startup.userAgents.count == 1)
        #expect(startup.userAgents[0].program == nil)
        #expect(startup.loginItems == nil)
        #expect(startup.brewServices == nil)
    }

    @Test func reportDistinguishesEmptyStartupCollectionsFromNull() throws {
        let json = """
        {
          "generatedAt": "2026-01-01T00:00:00.000Z",
          "rows": [],
          "startup": {
            "userAgents": [],
            "systemAgents": [],
            "systemDaemons": [],
            "loginItems": [],
            "brewServices": []
          }
        }
        """
        let report = try JSONDecoder().decode(Report.self, from: Data(json.utf8))

        let startup = try #require(report.startup)
        #expect(startup.loginItems?.isEmpty == true)
        #expect(startup.brewServices?.isEmpty == true)
    }

    @Test func startupOrphansGroupAllThreeSectionsInReportOrder() {
        let startup = StartupInfo(
            userAgents: [
                StartupEntry(
                    label: "user-present",
                    file: "/agents/user-present.plist",
                    program: "/bin/present",
                    status: "present"
                ),
                StartupEntry(
                    label: "user-orphan",
                    file: "/agents/user-orphan.plist",
                    program: "/bin/gone",
                    status: "missing"
                ),
            ],
            systemAgents: [
                StartupEntry(
                    label: "agent-orphan",
                    file: "/agents/agent-orphan.plist",
                    program: nil,
                    status: "missing"
                ),
                StartupEntry(
                    label: "agent-unknown",
                    file: "/agents/agent-unknown.plist",
                    program: nil,
                    status: "unknown"
                ),
            ],
            systemDaemons: [
                StartupEntry(
                    label: "daemon-orphan",
                    file: "/daemons/daemon-orphan.plist",
                    program: "/bin/gone",
                    status: "missing"
                ),
            ],
            loginItems: nil,
            brewServices: nil
        )

        #expect(startup.orphans.map(\.label) == ["user-orphan", "agent-orphan", "daemon-orphan"])
        #expect(startup.orphans.map(\.file) == [
            "/agents/user-orphan.plist",
            "/agents/agent-orphan.plist",
            "/daemons/daemon-orphan.plist",
        ])
        #expect(startup.orphans.allSatisfy { $0.isOrphan })
    }

    @Test func startupOrphansFromFixtureReport() throws {
        let report = try JSONDecoder().decode(Report.self, from: TestFixtures.reportData())
        let startup = try #require(report.startup)

        #expect(startup.orphans.map(\.label) == ["com.lwouis.alt-tab-macos"])
    }

    @Test func emptyOrMissingStartupHasNoOrphans() throws {
        let empty = StartupInfo(
            userAgents: [],
            systemAgents: [],
            systemDaemons: [],
            loginItems: nil,
            brewServices: nil
        )
        #expect(empty.orphans.isEmpty)

        let report = try JSONDecoder().decode(
            Report.self,
            from: Data(#"{"generatedAt":"2026-01-01T00:00:00.000Z","rows":[]}"#.utf8)
        )
        #expect(report.startup == nil)
        #expect((report.startup?.orphans ?? []).isEmpty)
    }

    @Test func reportDecodesInt64SizesExactly() throws {
        let json = """
        {
          "generatedAt": "2026-01-01T00:00:00.000Z",
          "rows": [
            {
              "id": "huge",
              "title": "Huge",
              "risk": "rebuild",
              "optIn": false,
              "app": null,
              "appRunning": false,
              "reclaim": "",
              "bytes": 9223372036854775807,
              "files": 1
            }
          ],
          "sweepableBytes": 9223372036854775807,
          "blockedBytes": 0,
          "optInBytes": 9007199254740993
        }
        """
        let report = try JSONDecoder().decode(Report.self, from: Data(json.utf8))

        #expect(report.rows[0].bytes == Int64.max)
        #expect(report.sweepableBytes == Int64.max)
        #expect(report.optInBytes == 9_007_199_254_740_993)
    }

    @Test func reportRejectsMalformedRequiredFields() {
        let cases = [
            #"{"generatedAt":"2026-01-01T00:00:00.000Z","rows":{}}"#,
            #"{"generatedAt":"2026-01-01T00:00:00.000Z","rows":"nope"}"#,
            #"{"generatedAt":"2026-01-01T00:00:00.000Z","rows":[null]}"#,
            #"{"generatedAt":42,"rows":[]}"#,
            #"{"generatedAt":"2026-01-01T00:00:00.000Z","rows":[{"title":"Missing id","risk":"rebuild","optIn":false,"appRunning":false,"reclaim":"","bytes":1,"files":1}]}"#,
        ]

        for json in cases {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Report.self, from: Data(json.utf8))
            }
        }
    }

    @Test func cleanResultToleratesUnknownKeysAndMapsEveryStatus() throws {
        let json = """
        {
          "schemaVersion": 1,
          "dryRun": false,
          "freedBytes": 12345678901,
          "futureTopLevel": "ignored",
          "results": [
            {"id":"a","title":"A","bytes":1,"status":"removed","futureRow":true},
            {"id":"b","title":"B","bytes":2,"status":"error","error":"permission denied"},
            {"id":"c","title":"C","bytes":3,"status":"future-status"},
            {"id":"d","title":"D","bytes":4,"status":"missing"},
            {"id":"e","title":"E","bytes":5,"status":"opt-in-skipped"},
            {"id":"f","title":"F","bytes":6,"status":"would-remove"}
          ]
        }
        """
        let result = try JSONDecoder().decode(CleanResult.self, from: Data(json.utf8))

        #expect(result.schemaVersion == 1)
        #expect(result.dryRun == false)
        #expect(result.freedBytes == 12_345_678_901)
        #expect(result.results.count == 6)
        #expect(result.results[0].cleanStatus == .removed)
        #expect(result.results[1].cleanStatus == .error)
        #expect(result.results[1].error == "permission denied")
        #expect(result.results[2].cleanStatus == nil)
        #expect(result.results[2].status == "future-status")
        #expect(result.results[3].cleanStatus == .missing)
        #expect(result.results[4].cleanStatus == .optInSkipped)
        #expect(result.results[5].cleanStatus == .wouldRemove)
    }

    @Test func cleanResultRejectsMalformedRequiredFields() {
        let cases = [
            #"{"results":{}}"#,
            #"{"results":"nope"}"#,
            #"{"results":[null]}"#,
            #"{"dryRun":true,"results":[{"id":"x","title":"X","bytes":1}]}"#,
            #"{"dryRun":true,"results":[{"id":"x","title":"X","bytes":1,"status":"removed"},{"id":"y","title":"Y","status":"removed"}]}"#,
        ]

        for json in cases {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CleanResult.self, from: Data(json.utf8))
            }
        }
    }


    @Test func summarySelectsSortsAndPassesThrough() throws {
        let report = try JSONDecoder().decode(Report.self, from: TestFixtures.reportData())
        let summary = report.summary()

        #expect(summary.safeRuleIDs == ["npm-cache", "voice-memos-cache", "pip-cache"])
        #expect(summary.reclaimables.map(\.id) == ["npm-cache", "voice-memos-cache", "pip-cache"])
        #expect(!summary.safeRuleIDs.contains("spotify-cache"))
        #expect(!summary.safeRuleIDs.contains("huggingface-cache"))
        #expect(summary.orphanCount == 1)
        #expect(summary.disk == report.disk)
        #expect(summary.memory == report.memory)
        #expect(summary.sweepableBytes == report.sweepableBytes)
        #expect(summary.blockedBytes == report.blockedBytes)
        #expect(summary.optInBytes == report.optInBytes)
    }

    @Test func summaryExcludesZeroRowsAndHonorsLimit() {
        let rows = [
            makeRow(id: "zero-cache", bytes: 0),
            makeRow(id: "running-cache", bytes: 2_000, appRunning: true),
            makeRow(id: "opt-in-cache", bytes: 1_000, optIn: true),
            makeRow(id: "safe-big", bytes: 100),
            makeRow(id: "safe-small", bytes: 10),
        ]
        let report = Report(generatedAt: "2026-01-01T00:00:00.000Z", rows: rows)

        let summary = report.summary(top: 1)
        #expect(summary.safeRuleIDs == ["safe-big", "safe-small"])
        #expect(summary.reclaimables.map(\.id) == ["safe-big"])
        #expect(summary.orphanCount == 0)

        let empty = report.summary(top: 0)
        #expect(empty.reclaimables.isEmpty)
        #expect(empty.safeRuleIDs == ["safe-big", "safe-small"])
    }

    @Test func byteFormatMatchesCLI() {
        let cases: [(Int64, String)] = [
            (0, "0 B"),
            (4096, "4.00 KB"),
            (297_222_144, "283 MB"),
            (58_834_944, "56.1 MB"),
            (52_261_801_984, "48.7 GB"),
            (147_742_081_024, "138 GB"),
            (4_294_967_296, "4.00 GB"),
        ]

        for (bytes, expected) in cases {
            #expect(ByteFormat.string(bytes) == expected, "bytes: \(bytes)")
        }
        #expect(ByteFormat.string(-1) == "0 B")
    }

    @Test func memoryPressureMapping() {
        #expect(MemoryPressure(level: 1) == .normal)
        #expect(MemoryPressure(level: 2) == .warning)
        #expect(MemoryPressure(level: 4) == .critical)
        #expect(MemoryPressure(level: 3) == .unknown)
        #expect(MemoryPressure(level: 0) == .unknown)

        #expect(MemoryPressure.normal.label == "normal")
        #expect(MemoryPressure.warning.label == "warning")
        #expect(MemoryPressure.critical.label == "critical")
        #expect(MemoryPressure.unknown.label == "unknown")
    }

    @Test func cleanResultDecodesAndMapsStatuses() throws {
        let result = try JSONDecoder().decode(CleanResult.self, from: TestFixtures.cleanJSON)

        #expect(result.schemaVersion == 1)
        #expect(result.dryRun)
        #expect(result.freedBytes == 0)
        #expect(result.results.count == 4)
        #expect(result.results[0].cleanStatus == .wouldRemove)
        #expect(result.results[2].cleanStatus == .skippedAppRunning)
        #expect(result.results[3].cleanStatus == .optInSkipped)

        let labels: [(CleanStatus, String)] = [
            (.removed, "Removed"),
            (.wouldRemove, "Would remove"),
            (.skippedAppRunning, "Skipped: app running"),
            (.optInSkipped, "Skipped: opt-in"),
            (.error, "Error"),
            (.missing, "Nothing to remove"),
        ]
        #expect(CleanStatus.allCases.count == labels.count)
        for (status, label) in labels {
            #expect(status.label == label)
        }
    }

    @Test func cleanResultDecodesWithoutOptionalFields() throws {
        let json = #"{"results":[{"id":"npm-cache","title":"npm cache","bytes":10,"status":"missing"}]}"#
        let result = try JSONDecoder().decode(CleanResult.self, from: Data(json.utf8))

        #expect(result.schemaVersion == nil)
        #expect(result.dryRun == false)
        #expect(result.freedBytes == 0)
        #expect(result.results.count == 1)
        #expect(result.results[0].error == nil)
        #expect(result.results[0].cleanStatus == .missing)
    }

    @Test func cleanResultRequiresResults() {
        let json = Data(#"{"schemaVersion":1,"dryRun":true,"freedBytes":0}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CleanResult.self, from: json)
        }
    }

    private func makeRow(
        id: String,
        bytes: Int64,
        optIn: Bool = false,
        appRunning: Bool = false
    ) -> RuleRow {
        RuleRow(
            id: id,
            title: id,
            risk: optIn ? "user-files" : "rebuild",
            optIn: optIn,
            app: appRunning ? "Test App" : nil,
            appRunning: appRunning,
            reclaim: "Test row.",
            bytes: bytes,
            files: 1
        )
    }
}
