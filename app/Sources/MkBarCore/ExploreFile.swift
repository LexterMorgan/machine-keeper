import Darwin
import Foundation

/// A captured filesystem identity. Device, inode, size, and nanosecond mtime
/// are recorded together so a later Trash attempt can detect a replaced file
/// without following a final symlink.
public struct FileIdentity: Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    public var modificationDate: Date {
        Date(
            timeIntervalSince1970: Double(modifiedSeconds)
                + Double(modifiedNanoseconds) / 1_000_000_000
        )
    }
}

/// One regular file found by an Explore scan. The URL and parent path are
/// already canonical, so the value can be revalidated before a Trash move.
public struct ExploreFile: Sendable, Equatable, Identifiable {
    /// Canonical file URL.
    public let url: URL

    /// Path below the scanned root, using `/` separators and no leading slash.
    public let relativePath: String

    /// Path below the current user's home, when the file is inside it. This is
    /// the form the protection policy is evaluated against.
    public let homeRelativePath: String?

    public let size: Int64
    public let modificationDate: Date
    public let identity: FileIdentity

    /// Canonical path of the containing directory at scan time.
    public let parentCanonicalPath: String

    public let isProtected: Bool
    public let protectionReason: String?

    public init(
        url: URL,
        relativePath: String,
        homeRelativePath: String?,
        size: Int64,
        modificationDate: Date,
        identity: FileIdentity,
        parentCanonicalPath: String,
        isProtected: Bool,
        protectionReason: String?
    ) {
        self.url = url
        self.relativePath = relativePath
        self.homeRelativePath = homeRelativePath
        self.size = size
        self.modificationDate = modificationDate
        self.identity = identity
        self.parentCanonicalPath = parentCanonicalPath
        self.isProtected = isProtected
        self.protectionReason = protectionReason
    }

    /// The canonical path is stable for the lifetime of a result row. Replaced
    /// files are detected by `identity`, not by this ID.
    public var id: String { url.path }
}

/// A location the scan deliberately did not enter or could not read.
public struct ExploreSkippedLocation: Sendable, Equatable, Identifiable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var id: String { "\(path)|\(reason)" }
}

/// The complete, possibly partial result of one Explore scan.
public struct ExploreScanResult: Sendable, Equatable {
    public let root: URL
    public let files: [ExploreFile]
    public let skipped: [ExploreSkippedLocation]
    public let isTruncated: Bool
    public let isCancelled: Bool
    public let resultLimit: Int

    public init(
        root: URL,
        files: [ExploreFile],
        skipped: [ExploreSkippedLocation],
        isTruncated: Bool,
        isCancelled: Bool,
        resultLimit: Int
    ) {
        self.root = root
        self.files = files
        self.skipped = skipped
        self.isTruncated = isTruncated
        self.isCancelled = isCancelled
        self.resultLimit = resultLimit
    }

    public var truncated: Bool { isTruncated }
    public var cancelled: Bool { isCancelled }
}

public enum ExploreError: Error, Sendable, Equatable, LocalizedError {
    case homeMissing(String)
    case homeNotDirectory(String)
    case rootMissing(String)
    case rootNotDirectory(String)
    case rootOutsideHome(String)
    case rootNotReadable(String)
    case rootHidden(String)
    case rootInHidden(String)
    case rootPackage(String)
    case rootInPackage(String)
    case rootMetadataUnavailable(String)
    case scanFailed(String)

    public var errorDescription: String? {
        switch self {
        case .homeMissing(let path):
            return "The home folder at \(path) does not exist."
        case .homeNotDirectory(let path):
            return "The home path \(path) is not a folder."
        case .rootMissing(let path):
            return "The selected folder \(path) does not exist."
        case .rootNotDirectory(let path):
            return "The selected path \(path) is not a folder."
        case .rootOutsideHome(let path):
            return "\(path) is outside your home folder. Choose a folder inside it."
        case .rootNotReadable(let path):
            return "The selected folder \(path) is not readable."
        case .rootHidden(let path):
            return "The selected folder \(path) is hidden. Choose a visible folder."
        case .rootInHidden(let path):
            return "The selected folder \(path) is inside a hidden folder."
        case .rootPackage(let path):
            return "The selected folder \(path) is an app bundle or package."
        case .rootInPackage(let path):
            return "The selected folder \(path) is inside an app bundle or package."
        case .rootMetadataUnavailable(let path):
            return "Could not verify whether \(path) is hidden or a package."
        case .scanFailed(let detail):
            return "The scan failed: \(detail)"
        }
    }
}

// MARK: - Package names

/// Finder or developer package folders that Explore never enters, even when
/// Launch Services does not report `isPackage` for them (frameworks and
/// Xcode project folders, for example).
enum ExplorePackage {
    static let extensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "pkg",
        "xcodeproj", "xcworkspace", "xcarchive", "playground", "rtfd",
        "photoslibrary", "musiclibrary", "fcpbundle", "logicx", "band",
        "scptd", "docset", "dsym",
    ]

    static func hasPackageComponent(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }
}

// MARK: - Metadata

struct FileSnapshot: Sendable {
    let identity: FileIdentity
    let mode: mode_t

    var isDirectory: Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    var isRegularFile: Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    var isSymbolicLink: Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }
}

enum FileMetadataError: Error, LocalizedError {
    case statFailed(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .statFailed(let path, let code):
            return "Could not read file information for \(path): \(String(cString: strerror(code)))"
        }
    }
}

enum FileMetadata {
    /// `lstat` deliberately does not follow a final symlink. Parent components
    /// are resolved by the kernel, which is what callers expect after they have
    /// canonicalized the parent separately.
    static func lstat(_ url: URL) throws -> FileSnapshot {
        try lstat(path: url.path)
    }

    static func lstat(path: String) throws -> FileSnapshot {
        var info = stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            throw FileMetadataError.statFailed(path: path, code: errno)
        }

        let seconds = Int64(info.st_mtimespec.tv_sec)
        let nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        let identity = FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: seconds,
            modifiedNanoseconds: nanoseconds
        )

        return FileSnapshot(identity: identity, mode: info.st_mode)
    }
}
