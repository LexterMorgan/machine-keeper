import Foundation

public enum ExploreTrashOutcome: String, Sendable, Equatable {
    case trashed
    case skipped
    case failed
}

/// The per-file result of an Explore Trash request. The caller removes only
/// `.trashed` entries from its result table and selection.
public struct ExploreTrashResult: Sendable, Equatable, Identifiable {
    public let fileID: String
    public let url: URL
    public let relativePath: String
    public let outcome: ExploreTrashOutcome
    public let message: String

    public init(
        fileID: String,
        url: URL,
        relativePath: String,
        outcome: ExploreTrashOutcome,
        message: String
    ) {
        self.fileID = fileID
        self.url = url
        self.relativePath = relativePath
        self.outcome = outcome
        self.message = message
    }

    public var id: String { fileID }
}

/// Revalidates selected Explore results and moves them to the macOS Trash.
///
/// Every move is preceded by a fresh canonical-home, canonical-root, and
/// canonical-parent check plus an `lstat` identity comparison. A file that
/// changed, moved, became a symlink or directory, landed in a hidden or
/// package path, or is protected is skipped and reported. This type never
/// permanently deletes anything; the only destructive operation is the
/// injected (or native) Trash closure.
public struct ExploreTrashService: Sendable {
    public typealias TrashOperation = @Sendable (URL) throws -> Void

    public let home: URL
    public let policy: ProtectionPolicy

    private let trashOperation: TrashOperation

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        policy: ProtectionPolicy,
        trashOperation: @escaping TrashOperation = ExploreTrashService.nativeTrash
    ) {
        self.home = home
        self.policy = policy
        self.trashOperation = trashOperation
    }

    /// The production operation. `FileManager.trashItem` uses the user's
    /// native Trash. There is no fallback to a permanent delete.
    public static let nativeTrash: TrashOperation = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public func trash(files: [ExploreFile], root: URL) async -> [ExploreTrashResult] {
        await Task.detached(priority: .userInitiated) {
            self.trashSynchronously(files: files, root: root)
        }.value
    }

    // MARK: - Revalidation

    private func trashSynchronously(files: [ExploreFile], root: URL) -> [ExploreTrashResult] {
        var seen = Set<String>()
        var results: [ExploreTrashResult] = []

        for file in files where seen.insert(file.id).inserted {
            results.append(trashOne(file, root: root))
        }
        return results
    }

    private func trashOne(_ file: ExploreFile, root: URL) -> ExploreTrashResult {
        func result(_ outcome: ExploreTrashOutcome, _ message: String) -> ExploreTrashResult {
            ExploreTrashResult(
                fileID: file.id,
                url: file.url,
                relativePath: file.relativePath,
                outcome: outcome,
                message: message
            )
        }

        // Re-resolve the home and chosen root for this file. A root swap,
        // rename, or symlink replacement invalidates the request.
        let canonicalHome = ExplorePath.canonical(home)
        let canonicalRoot = ExplorePath.canonical(root)

        guard let homeSnapshot = try? FileMetadata.lstat(canonicalHome),
              homeSnapshot.isDirectory
        else {
            return result(.skipped, "The home folder is no longer available.")
        }

        guard let rootSnapshot = try? FileMetadata.lstat(canonicalRoot),
              rootSnapshot.isDirectory
        else {
            return result(.skipped, "The selected folder is no longer available.")
        }

        guard ExplorePath.isWithin(canonicalRoot, root: canonicalHome) else {
            return result(.skipped, "The selected folder is outside your home folder.")
        }

        if isHidden(canonicalRoot, name: canonicalRoot.lastPathComponent) {
            return result(.skipped, "The selected folder is hidden.")
        }

        if isPackageOrApp(canonicalRoot, name: canonicalRoot.lastPathComponent) {
            return result(.skipped, "The selected folder is an app bundle or package.")
        }

        if let reason = policy.protectionReason(for: canonicalRoot, home: canonicalHome) {
            return result(.skipped, "The selected folder is protected: \(reason)")
        }

        // Check the file itself with lstat, which never follows a final
        // symlink. A directory can never be passed to the Trash operation.
        guard let originalSnapshot = try? FileMetadata.lstat(file.url) else {
            return result(.skipped, "The file could not be checked, so it was not moved to Trash.")
        }
        guard !originalSnapshot.isSymbolicLink else {
            return result(.skipped, "The file is a symbolic link, so it was not moved to Trash.")
        }
        guard !originalSnapshot.isDirectory else {
            return result(.skipped, "Only files can be moved to Trash, not folders.")
        }
        guard originalSnapshot.isRegularFile else {
            return result(.skipped, "The path is no longer a regular file.")
        }

        let originalName = file.url.lastPathComponent
        if isHidden(file.url, name: originalName) {
            return result(.skipped, "The file is hidden, so it was not moved to Trash.")
        }

        let canonicalParent = ExplorePath.canonical(file.url.deletingLastPathComponent())
        guard canonicalParent.path == file.parentCanonicalPath else {
            return result(.skipped, "The file's folder changed since it was scanned.")
        }
        guard let parentSnapshot = try? FileMetadata.lstat(canonicalParent),
              parentSnapshot.isDirectory
        else {
            return result(.skipped, "The file's folder could not be checked.")
        }
        guard ExplorePath.isWithin(canonicalParent, root: canonicalRoot),
              ExplorePath.isWithin(canonicalParent, root: canonicalHome)
        else {
            return result(.skipped, "The file is no longer inside the selected folder.")
        }

        let canonicalFile = canonicalParent.appendingPathComponent(originalName, isDirectory: false)
        guard ExplorePath.isWithin(canonicalFile, root: canonicalRoot),
              ExplorePath.isWithin(canonicalFile, root: canonicalHome)
        else {
            return result(.skipped, "The file is no longer inside the selected folder.")
        }

        if let relativeComponents = ExplorePath.relativeComponents(
            of: canonicalFile,
            in: canonicalHome
        ) {
            for component in relativeComponents {
                if component.hasPrefix(".") {
                    return result(.skipped, "The file is inside a hidden folder.")
                }
                if ExplorePackage.hasPackageComponent(component) {
                    return result(.skipped, "The file is inside an app bundle or package.")
                }
            }
        }

        if isPackageOrApp(canonicalFile, name: originalName) {
            return result(.skipped, "The file is an app bundle or package.")
        }
        if isInsidePackageOrApp(canonicalParent, root: canonicalRoot) {
            return result(.skipped, "The file is inside an app bundle or package.")
        }

        // Re-read the canonical path. This is the identity captured at scan
        // time, so a replaced file, a changed size, or a changed mtime is
        // skipped instead of moved.
        guard let currentSnapshot = try? FileMetadata.lstat(canonicalFile) else {
            return result(.skipped, "The file changed since it was scanned.")
        }
        guard !currentSnapshot.isSymbolicLink else {
            return result(.skipped, "The file is a symbolic link, so it was not moved to Trash.")
        }
        guard currentSnapshot.isRegularFile else {
            return result(.skipped, "The path is no longer a regular file.")
        }
        guard currentSnapshot.identity == file.identity else {
            return result(.skipped, "The file changed since it was scanned, so it was not moved to Trash.")
        }

        if let reason = policy.protectionReason(for: canonicalFile, home: canonicalHome) {
            return result(.skipped, "The file is protected: \(reason)")
        }

        // Remaining race: validation and `trashItem` are separate filesystem
        // calls, and FileManager offers no atomic "trash exactly this inode"
        // operation. Another process can still replace the path in the tiny
        // window after the final lstat. These checks target canonical paths and
        // shrink that window, but they cannot close it. The operation below is
        // the native Trash only, never a permanent delete.
        do {
            try trashOperation(canonicalFile)
            return result(.trashed, "Moved to Trash.")
        } catch {
            return result(
                .failed,
                "Could not move to Trash: \(error.localizedDescription)"
            )
        }
    }

    /// A directory can be a package even when the final file's own name is
    /// ordinary. Check every canonical parent component down to the chosen
    /// root so direct callers cannot trash package contents.
    private func isInsidePackageOrApp(_ directory: URL, root: URL) -> Bool {
        let rootComponents = ExplorePath.components(of: root)
        var current = ExplorePath.canonical(directory)

        while true {
            let components = ExplorePath.components(of: current)
            guard components.count > rootComponents.count else { return false }
            if isPackageOrApp(current, name: current.lastPathComponent) {
                return true
            }
            current = ExplorePath.canonical(current.deletingLastPathComponent())
        }
    }

    private func isHidden(_ url: URL, name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let values = try? url.resourceValues(forKeys: [.isHiddenKey])
        return values?.isHidden == true
    }

    private func isPackageOrApp(_ url: URL, name: String) -> Bool {
        if ExplorePackage.hasPackageComponent(name) { return true }
        let values = try? url.resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage == true
    }
}
