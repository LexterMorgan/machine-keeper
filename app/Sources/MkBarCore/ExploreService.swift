import Foundation

/// A bounded, cancellable, off-main recursive scan for regular files.
///
/// Safety choices made here:
/// - The root must canonicalize inside the current user's home and be a folder.
/// - Symlinked entries and symlinked folders are not followed.
/// - Hidden entries, `.app` bundles, and packages are not entered.
/// - Only regular files that are readable are returned.
/// - Results are capped; `isTruncated` is only set when an additional matching
///   file is actually found beyond the cap.
public struct ExploreService: Sendable {
    public let home: URL
    public let resultLimit: Int

    private let scanObserver: (@Sendable (Int) -> Void)?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        resultLimit: Int = 500
    ) {
        self.home = home
        self.resultLimit = max(1, resultLimit)
        self.scanObserver = nil
    }

    /// Test seam: the observer receives the number of matching files found so
    /// far and can cancel the current scan task to exercise cancellation.
    internal init(
        home: URL,
        resultLimit: Int = 500,
        scanObserver: @escaping @Sendable (Int) -> Void
    ) {
        self.home = home
        self.resultLimit = max(1, resultLimit)
        self.scanObserver = scanObserver
    }

    /// Resolves and validates a candidate root. Returns the canonical folder.
    public static func validateRoot(_ root: URL, home: URL) throws -> URL {
        let canonicalHome = ExplorePath.canonical(home)

        let homeSnapshot: FileSnapshot
        do {
            homeSnapshot = try FileMetadata.lstat(canonicalHome)
        } catch {
            throw ExploreError.homeMissing(canonicalHome.path)
        }
        guard homeSnapshot.isDirectory else {
            throw ExploreError.homeNotDirectory(canonicalHome.path)
        }

        let canonicalRoot = ExplorePath.canonical(root)
        let rootSnapshot: FileSnapshot
        do {
            rootSnapshot = try FileMetadata.lstat(canonicalRoot)
        } catch {
            throw ExploreError.rootMissing(canonicalRoot.path)
        }
        guard rootSnapshot.isDirectory else {
            throw ExploreError.rootNotDirectory(canonicalRoot.path)
        }
        guard ExplorePath.isWithin(canonicalRoot, root: canonicalHome) else {
            throw ExploreError.rootOutsideHome(canonicalRoot.path)
        }

        try validateExcludedAncestors(root: canonicalRoot, home: canonicalHome)

        guard FileManager.default.isReadableFile(atPath: canonicalRoot.path) else {
            throw ExploreError.rootNotReadable(canonicalRoot.path)
        }

        return canonicalRoot
    }

    /// A directly selected root is not special: it must obey the same hidden
    /// and package rules as every traversed directory, including its ancestors
    /// up to home. Metadata failure is a rejection, never a permissive guess.
    private static func validateExcludedAncestors(root: URL, home: URL) throws {
        var current = root
        while true {
            guard let snapshot = try? FileMetadata.lstat(current), snapshot.isDirectory else {
                throw ExploreError.rootMetadataUnavailable(current.path)
            }

            let values: URLResourceValues
            do {
                values = try current.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
            } catch {
                throw ExploreError.rootMetadataUnavailable(current.path)
            }

            let name = current.lastPathComponent
            if name.hasPrefix(".") || values.isHidden == true {
                if current.path == root.path {
                    throw ExploreError.rootHidden(current.path)
                }
                throw ExploreError.rootInHidden(current.path)
            }
            if ExplorePackage.hasPackageComponent(name) || values.isPackage == true {
                if current.path == root.path {
                    throw ExploreError.rootPackage(current.path)
                }
                throw ExploreError.rootInPackage(current.path)
            }

            if current.path == home.path {
                break
            }
            current = ExplorePath.canonical(current.deletingLastPathComponent())
            guard ExplorePath.isWithin(current, root: home) else {
                throw ExploreError.rootOutsideHome(current.path)
            }
        }
    }

    public func scan(
        root: URL,
        filters: ExploreFilters = ExploreFilters(),
        policy: ProtectionPolicy
    ) async throws -> ExploreScanResult {
        // The group child runs the blocking filesystem walk off the caller's
        // executor. Cancelling the caller cancels the child, and the walk
        // checks Task.isCancelled between entries.
        try await withThrowingTaskGroup(of: ExploreScanResult.self) { group in
            group.addTask {
                try self.scanSynchronously(root: root, filters: filters, policy: policy)
            }
            guard let result = try await group.next() else {
                throw ExploreError.scanFailed("No scan result was produced.")
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Synchronous walk

    private func scanSynchronously(
        root: URL,
        filters: ExploreFilters,
        policy: ProtectionPolicy
    ) throws -> ExploreScanResult {
        let canonicalHome = ExplorePath.canonical(home)
        let canonicalRoot = try Self.validateRoot(root, home: canonicalHome)
        let limit = max(1, resultLimit)

        var files: [ExploreFile] = []
        var skipped: [ExploreSkippedLocation] = []
        var isTruncated = false
        var isCancelled = false
        var shouldStop = false

        func skip(_ url: URL, _ reason: String) {
            skipped.append(ExploreSkippedLocation(path: url.path, reason: reason))
        }

        func isHidden(_ url: URL, name: String) -> Bool {
            if name.hasPrefix(".") { return true }
            let values = try? url.resourceValues(forKeys: [.isHiddenKey])
            return values?.isHidden == true
        }

        func isPackage(_ url: URL, name: String) -> Bool {
            if ExplorePackage.hasPackageComponent(name) { return true }
            let values = try? url.resourceValues(forKeys: [.isPackageKey])
            return values?.isPackage == true
        }

        // A manual FileManager walk is used instead of DirectoryEnumerator so
        // every skipped child can be reported with its exact path and reason,
        // and so a symlinked folder is never descended into.
        func walk(directory: URL, relativeDirectory: String) {
            if shouldStop { return }
            if Task.isCancelled {
                isCancelled = true
                shouldStop = true
                return
            }

            // Re-canonicalize every directory before reading it. If a folder
            // was swapped for a symlink after the entry check, this rejects the
            // outside target instead of enumerating it.
            let workingDirectory = ExplorePath.canonical(directory)
            guard ExplorePath.isWithin(workingDirectory, root: canonicalRoot),
                  ExplorePath.isWithin(workingDirectory, root: canonicalHome),
                  let directorySnapshot = try? FileMetadata.lstat(workingDirectory),
                  directorySnapshot.isDirectory
            else {
                skip(workingDirectory, "Folder is outside the selected folder.")
                return
            }

            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: workingDirectory,
                    includingPropertiesForKeys: [.isHiddenKey, .isPackageKey],
                    options: []
                )
            } catch {
                skip(workingDirectory, "Could not read folder: \(error.localizedDescription)")
                return
            }

            let ordered = entries.sorted { lhs, rhs in
                let left = lhs.lastPathComponent
                let right = rhs.lastPathComponent
                if left.compare(right, options: [.caseInsensitive]) != .orderedSame {
                    return left.compare(right, options: [.caseInsensitive]) == .orderedAscending
                }
                return left < right
            }

            for url in ordered {
                if shouldStop { return }
                if Task.isCancelled {
                    isCancelled = true
                    shouldStop = true
                    return
                }

                let name = url.lastPathComponent
                let snapshot: FileSnapshot
                do {
                    snapshot = try FileMetadata.lstat(url)
                } catch {
                    skip(url, "Could not read file information: \(error.localizedDescription)")
                    continue
                }

                if isHidden(url, name: name) {
                    skip(url, "Hidden")
                    continue
                }

                if snapshot.isSymbolicLink {
                    skip(url, "Symbolic link")
                    continue
                }

                if snapshot.isDirectory {
                    if isPackage(url, name: name) {
                        skip(url, "App bundle or package")
                        continue
                    }
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        skip(url, "Folder is not readable")
                        continue
                    }
                    let childRelative = relativeDirectory.isEmpty
                        ? name
                        : "\(relativeDirectory)/\(name)"
                    walk(directory: url, relativeDirectory: childRelative)
                    continue
                }

                guard snapshot.isRegularFile else {
                    skip(url, "Not a regular file")
                    continue
                }

                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    skip(url, "File is not readable")
                    continue
                }

                let modificationDate = snapshot.identity.modificationDate

                guard filters.matches(
                    name: name,
                    fileExtension: url.pathExtension,
                    size: snapshot.identity.size,
                    modifiedAt: modificationDate
                ) else {
                    continue
                }

                if files.count >= limit {
                    // A matching file exists beyond the cap. This is the only
                    // place truncation is proven, so an exact-cap result is
                    // not mislabeled.
                    isTruncated = true
                    shouldStop = true
                    return
                }

                let canonicalParent = ExplorePath.canonical(url.deletingLastPathComponent())
                let canonicalFile = canonicalParent.appendingPathComponent(name, isDirectory: false)
                guard ExplorePath.isWithin(canonicalParent, root: canonicalRoot),
                      ExplorePath.isWithin(canonicalParent, root: canonicalHome),
                      ExplorePath.isWithin(canonicalFile, root: canonicalRoot),
                      ExplorePath.isWithin(canonicalFile, root: canonicalHome)
                else {
                    skip(url, "File is outside the selected folder.")
                    continue
                }
                let homeRelativePath = ExplorePath.relativePath(of: canonicalFile, in: canonicalHome)

                let protectionReason: String?
                if let homeRelativePath {
                    protectionReason = policy.protectionReason(forRelativePath: homeRelativePath)
                } else {
                    protectionReason = "The file is outside the home folder."
                }
                let isProtected = protectionReason != nil

                let relativePath = relativeDirectory.isEmpty
                    ? name
                    : "\(relativeDirectory)/\(name)"

                files.append(
                    ExploreFile(
                        url: canonicalFile,
                        relativePath: relativePath,
                        homeRelativePath: homeRelativePath,
                        size: snapshot.identity.size,
                        modificationDate: modificationDate,
                        identity: snapshot.identity,
                        parentCanonicalPath: canonicalParent.path,
                        isProtected: isProtected,
                        protectionReason: protectionReason
                    )
                )

                scanObserver?(files.count)

                if Task.isCancelled {
                    isCancelled = true
                    shouldStop = true
                    return
                }
            }
        }

        walk(directory: canonicalRoot, relativeDirectory: "")

        files.sort { $0.url.path < $1.url.path }

        return ExploreScanResult(
            root: canonicalRoot,
            files: files,
            skipped: skipped,
            isTruncated: isTruncated,
            isCancelled: isCancelled,
            resultLimit: limit
        )
    }
}
