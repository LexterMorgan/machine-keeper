import Foundation

/// The combinable Explore filters. Empty or nil fields are inactive; every
/// active field must match (logical AND).
public struct ExploreFilters: Sendable, Equatable {
    /// Case-insensitive filename substring. Leading or trailing whitespace is
    /// ignored; an empty value matches every file.
    public var filenameContains: String

    /// Case-insensitive extension without the leading dot. A value like
    /// ".TXT" is accepted and treated as "txt".
    public var fileExtension: String

    /// Matches files whose size is greater than or equal to this value.
    public var minimumSizeBytes: Int64?

    /// Matches files modified at or after this date.
    public var modifiedAfter: Date?

    public init(
        filenameContains: String = "",
        fileExtension: String = "",
        minimumSizeBytes: Int64? = nil,
        modifiedAfter: Date? = nil
    ) {
        self.filenameContains = filenameContains
        self.fileExtension = fileExtension
        self.minimumSizeBytes = minimumSizeBytes
        self.modifiedAfter = modifiedAfter
    }

    public var isActive: Bool {
        !normalizedFilename.isEmpty
            || !normalizedExtension.isEmpty
            || minimumSizeBytes != nil
            || modifiedAfter != nil
    }

    public func matches(name: String, fileExtension: String?, size: Int64, modifiedAt: Date) -> Bool {
        if !normalizedFilename.isEmpty {
            guard name.range(of: normalizedFilename, options: [.caseInsensitive]) != nil else {
                return false
            }
        }

        if !normalizedExtension.isEmpty {
            guard let fileExtension else { return false }
            guard normalizedExtension == Self.normalizeExtension(fileExtension) else {
                return false
            }
        }

        if let minimumSizeBytes, size < minimumSizeBytes {
            return false
        }

        if let modifiedAfter, modifiedAt < modifiedAfter {
            return false
        }

        return true
    }

    public func matches(_ file: ExploreFile) -> Bool {
        matches(
            name: file.url.lastPathComponent,
            fileExtension: file.url.pathExtension,
            size: file.size,
            modifiedAt: file.modificationDate
        )
    }

    private var normalizedFilename: String {
        filenameContains.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedExtension: String {
        Self.normalizeExtension(fileExtension)
    }

    private static func normalizeExtension(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") {
            value.removeFirst()
        }
        return value
    }
}
