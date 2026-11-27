import Foundation
import MkBarCore
import Observation

/// Main-actor state for the Explore window. A scan generation and a stored
/// Task make folder and filter changes cancel stale work; a late result from an
/// older generation is discarded instead of replacing the current table.
@MainActor
@Observable
final class ExploreModel {
    let home: URL
    let resultLimit: Int
    private(set) var policy: ProtectionPolicy?
    let policyError: String?

    private(set) var selectedFolder: URL?
    private(set) var filters = ExploreFilters()
    private(set) var results: [ExploreFile] = []
    private(set) var skipped: [ExploreSkippedLocation] = []
    private(set) var isTruncated = false
    private(set) var isCancelled = false
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var folderError: String?
    private(set) var scanError: String?

    var selection: Set<String> = []

    private(set) var isConfirmingTrash = false
    private(set) var pendingTrashFiles: [ExploreFile] = []
    private(set) var pendingTrashRoot: URL?
    private(set) var isTrashing = false
    private(set) var trashResults: [ExploreTrashResult] = []
    private(set) var trashSummary: String?

    @ObservationIgnored private let service: ExploreService
    @ObservationIgnored private let trashService: ExploreTrashService?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        policy: ProtectionPolicy?,
        policyError: String? = nil,
        service: ExploreService? = nil,
        trashService: ExploreTrashService? = nil,
        debounce: Duration = .milliseconds(250)
    ) {
        self.home = home
        self.policy = policy
        self.policyError = policyError ?? (policy == nil
            ? "The protection policy is unavailable. Explore cannot scan or move files to Trash."
            : nil)
        let resolvedService = service ?? ExploreService(home: home)
        self.service = resolvedService
        self.resultLimit = resolvedService.resultLimit
        self.trashService = trashService ?? policy.map {
            ExploreTrashService(home: home, policy: $0)
        }
        self.debounce = debounce
    }

    /// The app's production model: load `policy.json` from the app bundle and
    /// fail closed when it cannot be read.
    static func loadDefault(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExploreModel {
        do {
            let policy = try ProtectionPolicy.loadBundled()
            return ExploreModel(home: home, policy: policy)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return ExploreModel(
                home: home,
                policy: nil,
                policyError: "Could not load policy.json from the app bundle. "
                    + "\(detail) Trash is disabled."
            )
        }
    }

    // MARK: - Derived state

    var isPolicyLoaded: Bool { policy != nil }

    var selectedFiles: [ExploreFile] {
        results.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    var selectedProtectedFiles: [ExploreFile] {
        selectedFiles.filter(\.isProtected)
    }

    var rootProtectionReason: String? {
        guard let policy, let selectedFolder else { return nil }
        return policy.protectionReason(for: selectedFolder, home: home)
    }

    var trashIssues: [ExploreTrashResult] {
        trashResults.filter { $0.outcome != .trashed }
    }

    var canRequestTrash: Bool {
        trashDisabledReason == nil
    }

    /// A single explanation for why the Trash button is disabled. When this is
    /// nil the button is enabled.
    var trashDisabledReason: String? {
        guard isPolicyLoaded else {
            return policyError ?? "The protection policy is unavailable. Trash is disabled."
        }
        guard selectedFolder != nil else {
            return "Choose a folder first."
        }
        guard trashService != nil else {
            return "Trash is unavailable in this build."
        }
        if isScanning {
            return "Wait for the scan to finish."
        }
        if isTrashing {
            return "Moving files to Trash."
        }
        if isConfirmingTrash {
            return "Confirm or cancel the current Trash request."
        }
        if let rootProtectionReason {
            return "Trash is disabled for this folder. \(rootProtectionReason)"
        }
        if let protected = selectedProtectedFiles.first {
            let reason = protected.protectionReason ?? "This location is protected."
            return "Trash is disabled while the selection includes protected files. \(reason)"
        }
        if selection.isEmpty {
            return "Select files to move to Trash."
        }
        return nil
    }

    // MARK: - Folder and scan

    /// Validates a folder chosen outside the model (for example by NSOpenPanel)
    /// and starts a fresh scan. An invalid choice leaves the current folder and
    /// results untouched.
    func selectFolder(_ url: URL) {
        guard !isTrashing else { return }
        guard isPolicyLoaded else {
            folderError = policyError ?? "The protection policy is unavailable."
            return
        }

        do {
            let canonical = try ExploreService.validateRoot(url, home: home)
            selectedFolder = canonical
            folderError = nil
            resetForScopeChange()
            scheduleScan(immediately: true)
        } catch {
            folderError = Self.message(for: error)
        }
    }

    /// Applies filters, clears the selection immediately, and schedules a
    /// debounced rescan of the current folder.
    func setFilters(_ newFilters: ExploreFilters) {
        guard !isTrashing else { return }
        guard newFilters != filters else { return }
        filters = newFilters

        generation += 1
        scanTask?.cancel()
        debounceTask?.cancel()
        selection.removeAll()
        clearPendingTrash()
        results = []
        skipped = []
        isTruncated = false
        isCancelled = false
        isScanning = false
        hasScanned = false
        scanError = nil
        trashResults = []
        trashSummary = nil

        if selectedFolder != nil, isPolicyLoaded {
            scheduleScan(immediately: false)
        }
    }

    func rescan() {
        guard !isTrashing, isPolicyLoaded else { return }
        scheduleScan(immediately: true)
    }

    func cancelScan() {
        guard !isTrashing, isScanning else { return }
        scanTask?.cancel()
        debounceTask?.cancel()
        isScanning = false
        isCancelled = true
    }

    func selectAll() {
        selection = Set(results.map(\.id))
    }

    func selectUnprotected() {
        selection = Set(results.filter { !$0.isProtected }.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    /// Wait hook for tests and for any caller that needs the debounce and scan
    /// to settle. The UI itself does not block on it.
    func waitForScanToFinish() async {
        await debounceTask?.value
        await scanTask?.value
    }

    private func resetForScopeChange() {
        generation += 1
        scanTask?.cancel()
        debounceTask?.cancel()
        selection.removeAll()
        clearPendingTrash()
        results = []
        skipped = []
        isTruncated = false
        isCancelled = false
        isScanning = false
        hasScanned = false
        scanError = nil
        trashResults = []
        trashSummary = nil
    }

    private func scheduleScan(immediately: Bool) {
        debounceTask?.cancel()

        guard isPolicyLoaded, selectedFolder != nil else { return }

        if immediately {
            startScan()
            return
        }

        let delay = debounce
        isScanning = true
        debounceTask = Task { [weak self] in
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.startScan()
        }
    }

    private func startScan() {
        guard !isTrashing, let policy, let folder = selectedFolder else { return }

        generation += 1
        let scanGeneration = generation
        scanTask?.cancel()
        debounceTask?.cancel()

        selection.removeAll()
        clearPendingTrash()
        results = []
        skipped = []
        isTruncated = false
        isCancelled = false
        isScanning = true
        hasScanned = false
        scanError = nil
        trashResults = []
        trashSummary = nil

        let filters = self.filters
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.scan(
                    root: folder,
                    filters: filters,
                    policy: policy
                )
                guard self.generation == scanGeneration else { return }
                self.apply(result)
            } catch {
                guard self.generation == scanGeneration else { return }
                self.isScanning = false
                self.hasScanned = true
                if Task.isCancelled {
                    self.isCancelled = true
                } else {
                    self.scanError = Self.message(for: error)
                }
            }
        }
    }

    private func apply(_ result: ExploreScanResult) {
        results = result.files
        skipped = result.skipped
        isTruncated = result.isTruncated
        isCancelled = result.isCancelled || isCancelled
        isScanning = false
        hasScanned = true
        selection.removeAll()
    }

    // MARK: - Trash

    func requestTrash() {
        guard canRequestTrash, let root = selectedFolder else { return }
        let files = selectedFiles
        guard !files.isEmpty else { return }

        pendingTrashFiles = files
        pendingTrashRoot = root
        isConfirmingTrash = true
        trashResults = []
        trashSummary = nil
    }

    func cancelTrashConfirmation() {
        guard !isTrashing else { return }
        isConfirmingTrash = false
        pendingTrashFiles = []
        pendingTrashRoot = nil
    }

    func confirmTrash() async {
        guard !isTrashing,
              let trashService,
              let root = pendingTrashRoot,
              !pendingTrashFiles.isEmpty
        else {
            return
        }

        let files = pendingTrashFiles
        isTrashing = true
        trashResults = []
        trashSummary = nil

        let outcomes = await trashService.trash(files: files, root: root)
        trashResults = outcomes

        let successIDs = Set(
            outcomes.filter { $0.outcome == .trashed }.map(\.fileID)
        )
        let movedBytes = files
            .filter { successIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
        results.removeAll { successIDs.contains($0.id) }
        selection.subtract(successIDs)

        let successCount = successIDs.count
        let issueCount = outcomes.count - successCount
        if successCount == 0 {
            trashSummary = "No files were moved to Trash."
        } else if successCount == 1 {
            trashSummary = issueCount == 0
                ? "Moved 1 file (\(ByteFormat.string(movedBytes))) to Trash."
                : "Moved 1 file (\(ByteFormat.string(movedBytes))) to Trash. \(issueCount) could not be moved."
        } else {
            trashSummary = issueCount == 0
                ? "Moved \(successCount) files (\(ByteFormat.string(movedBytes))) to Trash."
                : "Moved \(successCount) files (\(ByteFormat.string(movedBytes))) to Trash. \(issueCount) could not be moved."
        }

        isTrashing = false
        isConfirmingTrash = false
        pendingTrashFiles = []
        pendingTrashRoot = nil
    }

    private func clearPendingTrash() {
        isConfirmingTrash = false
        pendingTrashFiles = []
        pendingTrashRoot = nil
    }

    // MARK: - Errors

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
