import Foundation

/// The two directory flags Explore needs. Each is optional because a
/// successful resource-value read can still omit the key; `nil` means unknown,
/// never false.
public struct ExploreDirectoryFlags: Sendable, Equatable {
    public let isHidden: Bool?
    public let isPackage: Bool?

    public init(isHidden: Bool?, isPackage: Bool?) {
        self.isHidden = isHidden
        self.isPackage = isPackage
    }
}

public typealias ExploreDirectoryMetadataReader =
    @Sendable (URL) throws -> ExploreDirectoryFlags

public enum ExploreDirectoryMetadata {
    /// Production reader. Both keys are requested together; a thrown lookup is
    /// propagated so callers can reject rather than guess.
    public static let live: ExploreDirectoryMetadataReader = { url in
        let values = try url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
        return ExploreDirectoryFlags(
            isHidden: values.isHidden,
            isPackage: values.isPackage
        )
    }
}

enum ExploreDirectoryExclusion: Sendable, Equatable {
    case hidden
    case package
    case metadataUnavailable
}

/// One decision for both scan-root validation and pre-Trash ancestor checks.
/// Dot names and package names remain exclusions even when metadata is known;
/// unknown metadata always excludes and carries no permissive fallback.
enum ExploreDirectoryPolicy {
    static func exclusion(
        name: String,
        flags: ExploreDirectoryFlags
    ) -> ExploreDirectoryExclusion? {
        guard flags.isHidden != nil, flags.isPackage != nil else {
            return .metadataUnavailable
        }
        if name.hasPrefix(".") || flags.isHidden == true {
            return .hidden
        }
        if ExplorePackage.hasPackageComponent(name) || flags.isPackage == true {
            return .package
        }
        return nil
    }
}
