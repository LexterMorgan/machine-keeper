import Foundation

/// A view of a `Report` with the reclaimable rules already chosen.
///
/// The CLI remains the source of truth: this type only filters and sorts the
/// rows from the report. It never decides which paths are safe.
public struct ReportSummary: Sendable, Equatable {
    public let disk: DiskInfo?
    public let memory: MemoryInfo?
    public let reclaimables: [RuleRow]
    public let safeRuleIDs: [String]
    public let sweepableBytes: Int64
    public let blockedBytes: Int64
    public let optInBytes: Int64
    public let orphanCount: Int

    public init(
        disk: DiskInfo?,
        memory: MemoryInfo?,
        reclaimables: [RuleRow],
        safeRuleIDs: [String],
        sweepableBytes: Int64,
        blockedBytes: Int64,
        optInBytes: Int64,
        orphanCount: Int
    ) {
        self.disk = disk
        self.memory = memory
        self.reclaimables = reclaimables
        self.safeRuleIDs = safeRuleIDs
        self.sweepableBytes = sweepableBytes
        self.blockedBytes = blockedBytes
        self.optInBytes = optInBytes
        self.orphanCount = orphanCount
    }
}

public extension Report {
    /// Selects rules that are safe to clean: not opt-in, not owned by a
    /// running app, and actually reclaiming bytes. The order is descending by
    /// size, with the rule id as a stable tie-breaker.
    func summary(top limit: Int = 3) -> ReportSummary {
        let safeRows = rows
            .filter { !$0.optIn && !$0.appRunning && $0.bytes > 0 }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes {
                    return lhs.bytes > rhs.bytes
                }
                return lhs.id < rhs.id
            }

        let orphanCount: Int
        if let startup {
            orphanCount = (startup.userAgents + startup.systemAgents + startup.systemDaemons)
                .filter(\.isOrphan)
                .count
        } else {
            orphanCount = 0
        }

        return ReportSummary(
            disk: disk,
            memory: memory,
            reclaimables: Array(safeRows.prefix(max(0, limit))),
            safeRuleIDs: safeRows.map(\.id),
            sweepableBytes: sweepableBytes,
            blockedBytes: blockedBytes,
            optInBytes: optInBytes,
            orphanCount: orphanCount
        )
    }
}
