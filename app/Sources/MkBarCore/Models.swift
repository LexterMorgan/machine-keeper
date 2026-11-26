import Foundation

// MARK: - Report

/// The read-only snapshot emitted by `mk report --json`.
public struct Report: Sendable, Decodable, Equatable {
    public let schemaVersion: Int?
    public let generatedAt: String
    public let home: String?
    public let disk: DiskInfo?
    public let memory: MemoryInfo?
    public let rows: [RuleRow]
    public let optInRows: [RuleRow]
    public let sweepableBytes: Int64
    public let blockedBytes: Int64
    public let optInBytes: Int64
    public let startup: StartupInfo?

    public init(
        schemaVersion: Int? = nil,
        generatedAt: String,
        home: String? = nil,
        disk: DiskInfo? = nil,
        memory: MemoryInfo? = nil,
        rows: [RuleRow],
        optInRows: [RuleRow] = [],
        sweepableBytes: Int64 = 0,
        blockedBytes: Int64 = 0,
        optInBytes: Int64 = 0,
        startup: StartupInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.home = home
        self.disk = disk
        self.memory = memory
        self.rows = rows
        self.optInRows = optInRows
        self.sweepableBytes = sweepableBytes
        self.blockedBytes = blockedBytes
        self.optInBytes = optInBytes
        self.startup = startup
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case home
        case disk
        case memory
        case rows
        case optInRows
        case sweepableBytes
        case blockedBytes
        case optInBytes
        case startup
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        home = try container.decodeIfPresent(String.self, forKey: .home)
        disk = try container.decodeIfPresent(DiskInfo.self, forKey: .disk)
        memory = try container.decodeIfPresent(MemoryInfo.self, forKey: .memory)
        rows = try container.decode([RuleRow].self, forKey: .rows)
        optInRows = try container.decodeIfPresent([RuleRow].self, forKey: .optInRows) ?? []
        sweepableBytes = try container.decodeIfPresent(Int64.self, forKey: .sweepableBytes) ?? 0
        blockedBytes = try container.decodeIfPresent(Int64.self, forKey: .blockedBytes) ?? 0
        optInBytes = try container.decodeIfPresent(Int64.self, forKey: .optInBytes) ?? 0
        startup = try container.decodeIfPresent(StartupInfo.self, forKey: .startup)
    }
}

public struct DiskInfo: Sendable, Decodable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let percent: String

    public init(totalBytes: Int64, usedBytes: Int64, freeBytes: Int64, percent: String) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.percent = percent
    }
}

public struct SwapInfo: Sendable, Decodable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
    }
}

public struct MemoryInfo: Sendable, Decodable, Equatable {
    public let swap: SwapInfo
    public let pressureLevel: Int
    public let pressureLabel: String
    public let wiredBytes: Int64
    public let compressorBytes: Int64
    public let freeBytes: Int64

    /// Activity Monitor-style counters added after schema version 1. They are
    /// optional so an older report still decodes; `usedBytes` is app + wired +
    /// compressor, and is null when macOS did not report anonymous pages.
    public let totalBytes: Int64?
    public let usedBytes: Int64?
    public let appBytes: Int64?
    public let cachedBytes: Int64?

    public init(
        swap: SwapInfo,
        pressureLevel: Int,
        pressureLabel: String,
        wiredBytes: Int64,
        compressorBytes: Int64,
        freeBytes: Int64,
        totalBytes: Int64? = nil,
        usedBytes: Int64? = nil,
        appBytes: Int64? = nil,
        cachedBytes: Int64? = nil
    ) {
        self.swap = swap
        self.pressureLevel = pressureLevel
        self.pressureLabel = pressureLabel
        self.wiredBytes = wiredBytes
        self.compressorBytes = compressorBytes
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.cachedBytes = cachedBytes
    }
}

public struct RuleRow: Sendable, Decodable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let risk: String
    public let optIn: Bool
    public let app: String?
    public let appRunning: Bool
    public let reclaim: String
    public let bytes: Int64
    public let files: Int

    public init(
        id: String,
        title: String,
        risk: String,
        optIn: Bool,
        app: String?,
        appRunning: Bool,
        reclaim: String,
        bytes: Int64,
        files: Int
    ) {
        self.id = id
        self.title = title
        self.risk = risk
        self.optIn = optIn
        self.app = app
        self.appRunning = appRunning
        self.reclaim = reclaim
        self.bytes = bytes
        self.files = files
    }
}

public struct StartupInfo: Sendable, Decodable, Equatable {
    public let userAgents: [StartupEntry]
    public let systemAgents: [StartupEntry]
    public let systemDaemons: [StartupEntry]
    public let loginItems: [String]?
    public let brewServices: [BrewService]?

    public init(
        userAgents: [StartupEntry],
        systemAgents: [StartupEntry],
        systemDaemons: [StartupEntry],
        loginItems: [String]?,
        brewServices: [BrewService]?
    ) {
        self.userAgents = userAgents
        self.systemAgents = systemAgents
        self.systemDaemons = systemDaemons
        self.loginItems = loginItems
        self.brewServices = brewServices
    }

    /// Every orphaned launchd entry, in report order: user agents, then
    /// system agents, then system daemons. A derived view of the decoded
    /// report; it does not change what the engine audits.
    public var orphans: [StartupEntry] {
        (userAgents + systemAgents + systemDaemons).filter(\.isOrphan)
    }
}

public struct StartupEntry: Sendable, Decodable, Equatable {
    public let label: String
    public let file: String
    public let program: String?
    public let status: String

    public init(label: String, file: String, program: String?, status: String) {
        self.label = label
        self.file = file
        self.program = program
        self.status = status
    }

    /// An orphan is a launchd entry whose program no longer exists.
    public var isOrphan: Bool {
        status == "missing"
    }
}

public struct BrewService: Sendable, Decodable, Equatable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

// MARK: - Clean

/// The result emitted by `mk clean --json` (dry run or real).
public struct CleanResult: Sendable, Decodable, Equatable {
    public let schemaVersion: Int?
    public let dryRun: Bool
    public let results: [CleanRow]
    public let freedBytes: Int64

    public init(schemaVersion: Int?, dryRun: Bool, results: [CleanRow], freedBytes: Int64) {
        self.schemaVersion = schemaVersion
        self.dryRun = dryRun
        self.results = results
        self.freedBytes = freedBytes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case dryRun
        case results
        case freedBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        results = try container.decode([CleanRow].self, forKey: .results)
        freedBytes = try container.decodeIfPresent(Int64.self, forKey: .freedBytes) ?? 0
    }
}

public struct CleanRow: Sendable, Decodable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let bytes: Int64
    public let status: String
    public let error: String?

    public init(id: String, title: String, bytes: Int64, status: String, error: String?) {
        self.id = id
        self.title = title
        self.bytes = bytes
        self.status = status
        self.error = error
    }

    public var cleanStatus: CleanStatus? {
        CleanStatus(rawValue: status)
    }
}

public enum CleanStatus: String, Sendable, CaseIterable {
    case removed
    case wouldRemove = "would-remove"
    case skippedAppRunning = "skipped-app-running"
    case optInSkipped = "opt-in-skipped"
    case error
    case missing

    public var label: String {
        switch self {
        case .removed:
            return "Removed"
        case .wouldRemove:
            return "Would remove"
        case .skippedAppRunning:
            return "Skipped: app running"
        case .optInSkipped:
            return "Skipped: opt-in"
        case .error:
            return "Error"
        case .missing:
            return "Nothing to remove"
        }
    }
}
