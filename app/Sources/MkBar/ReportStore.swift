import Foundation
import MkBarCore
import Observation

@MainActor
@Observable
final class ReportStore {
    static let shared = ReportStore()

    private(set) var report: Report?
    private(set) var summary: ReportSummary?
    private(set) var errorMessage: String?
    private(set) var setupHint: String?
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    private(set) var cleanPreview: CleanResult?
    private(set) var isPreviewing = false
    private(set) var previewError: String?
    private(set) var isCleaning = false
    private(set) var cleanOutcome: String?
    private(set) var cleanOutcomeDetail: String?
    private(set) var cleanOutcomeIsSuccess = false
    private(set) var cleanError: String?

    private let service: MKService
    private var pollingTask: Task<Void, Never>?
    private var refreshInFlight = false

    init(service: MKService = MKService()) {
        self.service = service
    }

    var isBusy: Bool { isLoading || isPreviewing || isCleaning }
    var safeRuleCount: Int { summary?.safeRuleIDs.count ?? 0 }
    var hasSafeRules: Bool { safeRuleCount > 0 }

    func startPolling() {
        guard pollingTask == nil else { return }

        // The store is a singleton that lives as long as the app; capturing it
        // strongly is the honest lifetime here.
        pollingTask = Task {
            await refresh()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshIfStale(maxAge: TimeInterval = 30) async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        // A poll must not replace the report while a clean or dry run is
        // measuring it. Operations refresh explicitly when they finish.
        guard !isCleaning, !isPreviewing else { return }
        await loadReport(clearingCleanOutcome: true)
    }

    func previewClean() async {
        if cleanPreview != nil {
            dismissPreview()
            return
        }
        guard !isPreviewing, !isCleaning else { return }

        isPreviewing = true
        previewError = nil
        defer { isPreviewing = false }

        do {
            cleanPreview = try await service.previewClean()
        } catch {
            cleanPreview = nil
            previewError = Self.inlineDescription(error)
        }
    }

    func dismissPreview() {
        cleanPreview = nil
        previewError = nil
    }

    func cleanSafe() async {
        guard !isCleaning else { return }

        let ids = summary?.safeRuleIDs ?? []
        guard !ids.isEmpty else {
            clearCleanOutcome()
            cleanError = "Nothing safe to clean right now."
            return
        }

        isCleaning = true
        clearCleanOutcome()
        cleanError = nil

        do {
            let result = try await service.clean(ruleIDs: ids)
            applyCleanOutcome(result)
            dismissPreview()
        } catch {
            cleanError = Self.inlineDescription(error)
        }

        // Keep isCleaning true through the final read: it blocks polling, and
        // the refresh preserves the outcome this operation just recorded.
        await refreshAfterClean()
        isCleaning = false
    }

    // MARK: - Report loading

    private func loadReport(clearingCleanOutcome: Bool) async {
        guard !refreshInFlight else { return }

        refreshInFlight = true
        isLoading = true
        defer {
            refreshInFlight = false
            isLoading = false
        }

        if clearingCleanOutcome {
            clearCleanOutcome()
        }

        do {
            let fresh = try await service.loadReport()
            report = fresh
            summary = fresh.summary()
            errorMessage = nil
            setupHint = nil
            lastUpdated = Date()
        } catch {
            // Keep the last good report and summary on screen; only the status
            // line changes.
            let described = Self.describe(error)
            errorMessage = described.message
            setupHint = described.hint
        }
    }

    /// A poll may already be reading when a clean finishes. Let it drain so
    /// the post-clean read is not silently dropped.
    private func refreshAfterClean() async {
        while refreshInFlight {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        await loadReport(clearingCleanOutcome: false)
    }

    // MARK: - Clean outcome

    /// `mk clean` exits 0 even when individual rules fail or are skipped, so
    /// the result rows decide whether this was a clean success.
    private func applyCleanOutcome(_ result: CleanResult) {
        let errors = result.results.filter { $0.cleanStatus == .error }
        let skipped = result.results.filter {
            $0.cleanStatus == .skippedAppRunning || $0.cleanStatus == .optInSkipped
        }

        cleanOutcomeDetail = errors
            .compactMap(\.error)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let freed = ByteFormat.string(result.freedBytes)
        let failed = errors.count == 1 ? "1 rule failed" : "\(errors.count) rules failed"

        if result.freedBytes > 0, errors.isEmpty {
            cleanOutcome = "Freed \(freed)"
            cleanOutcomeIsSuccess = true
            return
        }

        cleanOutcomeIsSuccess = false
        if result.freedBytes > 0 {
            let skippedPart = skipped.isEmpty ? "" : "\(skipped.count) skipped, "
            cleanOutcome = "Freed \(freed) — \(skippedPart)\(failed)."
        } else if errors.isEmpty {
            cleanOutcome = skipped.isEmpty
                ? "Nothing removed — nothing was left to clean."
                : "Nothing removed — \(skipped.count) skipped."
        } else {
            let skippedPart = skipped.isEmpty ? "" : "\(skipped.count) skipped, "
            cleanOutcome = "Nothing removed — \(skippedPart)\(failed)."
        }
    }

    private func clearCleanOutcome() {
        cleanOutcome = nil
        cleanOutcomeDetail = nil
        cleanOutcomeIsSuccess = false
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> (message: String, hint: String?) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return (message, (error as? LocatorError)?.setupHint)
    }

    private static func inlineDescription(_ error: Error) -> String {
        let described = describe(error)
        guard let hint = described.hint, !hint.isEmpty else { return described.message }
        return "\(described.message) \(hint)"
    }
}
