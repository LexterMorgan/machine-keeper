import Foundation

/// Canonical path helpers shared by Explore scanning and its Trash
/// revalidation. Symlinked ancestors are resolved before any containment
/// check. Containment compares actual canonical components exactly, so
/// `Work` and `work` stay distinct on a case-sensitive volume. Protected-name
/// matching remains case-insensitive because the policy names are labels, not
/// filesystem ancestry.
public enum ExplorePath {
    /// The one canonical form used everywhere: standardized and with symlinks
    /// resolved.
    public static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// The canonical path split into components. The volume root component is
    /// not included, so containment is always component based and `/Users/lex`
    /// can never be a prefix of `/Users/lex-other`.
    public static func components(of url: URL) -> [String] {
        canonical(url).pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    /// True when `candidate` is `root` itself or a descendant of it.
    public static func isWithin(_ candidate: URL, root: URL) -> Bool {
        relativeComponents(of: candidate, in: root) != nil
    }

    /// The path components below `root`, or nil when `candidate` is outside.
    public static func relativeComponents(of candidate: URL, in root: URL) -> [String]? {
        let candidateComponents = components(of: candidate)
        let rootComponents = components(of: root)
        guard candidateComponents.count >= rootComponents.count else { return nil }

        for index in rootComponents.indices {
            // Containment is filesystem identity, not a case-folded label.
            // `realpath`/canonicalization has already resolved symlinks and
            // normalized the path; exact components preserve case-sensitive
            // siblings such as Work and work.
            guard candidateComponents[index] == rootComponents[index] else {
                return nil
            }
        }
        return Array(candidateComponents[rootComponents.count...])
    }

    /// The slash-separated path below `root`; an empty string means the two
    /// URLs are the same canonical path. Returns nil when `candidate` is
    /// outside `root`.
    public static func relativePath(of candidate: URL, in root: URL) -> String? {
        relativeComponents(of: candidate, in: root)?.joined(separator: "/")
    }

    /// Component-wise equality with case folding, used only for protected
    /// policy names. Containment must not use this on case-sensitive volumes.
    public static func sameComponent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive]) == .orderedSame
    }
}

/// The app's copy of `policy.json`. `neverTouch` is the registry protection
/// list shared with the CLI; `exploreProtectedRoots` makes Explore's Trash
/// surface read-only for additional folders such as `~/Library`.
public struct ProtectionPolicy: Sendable, Equatable {
    public let neverTouch: [String]
    public let exploreProtectedRoots: [String]

    private let neverTouchComponents: [[String]]
    private let exploreProtectedComponents: [[String]]

    public init(neverTouch: [String], exploreProtectedRoots: [String] = []) {
        self.neverTouch = neverTouch
        self.exploreProtectedRoots = exploreProtectedRoots
        self.neverTouchComponents = Self.normalize(neverTouch)
        self.exploreProtectedComponents = Self.normalize(exploreProtectedRoots)
    }

    /// Loads and validates the policy document. Any unreadable, malformed,
    /// unsupported, or empty policy fails instead of yielding permissive
    /// defaults.
    public static func load(from url: URL) throws -> ProtectionPolicy {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProtectionPolicyError.unreadable(path: url.path, detail: error.localizedDescription)
        }

        let document: PolicyDocument
        do {
            document = try JSONDecoder().decode(PolicyDocument.self, from: data)
        } catch {
            throw ProtectionPolicyError.invalid(detail: "The policy is not valid JSON: \(error.localizedDescription)")
        }

        guard document.schemaVersion == 1 else {
            throw ProtectionPolicyError.unsupportedSchemaVersion(document.schemaVersion)
        }
        try validateList(document.neverTouch, name: "neverTouch", allowEmpty: false)
        try validateList(
            document.exploreProtectedRoots,
            name: "exploreProtectedRoots",
            allowEmpty: true
        )

        return ProtectionPolicy(
            neverTouch: document.neverTouch,
            exploreProtectedRoots: document.exploreProtectedRoots
        )
    }

    /// Loads `policy.json` from the app bundle's Resources directory. A missing
    /// resource is an error: Explore never falls back to an empty policy.
    public static func loadBundled(in bundle: Bundle = .main) throws -> ProtectionPolicy {
        guard let url = bundle.url(forResource: "policy", withExtension: "json") else {
            throw ProtectionPolicyError.missingBundledResource
        }
        return try load(from: url)
    }

    /// The first matching protection reason for a path, with the most specific
    /// configured prefix winning. The path must be inside `home`; an outside
    /// path is not protected by this policy and callers must reject it for
    /// another reason.
    public func protectionReason(for url: URL, home: URL) -> String? {
        guard let relativePath = ExplorePath.relativePath(of: url, in: home) else {
            return nil
        }
        return protectionReason(forRelativePath: relativePath)
    }

    /// Same check as `protectionReason(for:home:)` but for an already
    /// home-relative path.
    public func protectionReason(forRelativePath relativePath: String) -> String? {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return nil }

        if let match = Self.matchingPrefix(in: neverTouchComponents, for: components) {
            return "~/\(match.joined(separator: "/")) is on the never-touch list."
        }

        if let match = Self.matchingPrefix(in: exploreProtectedComponents, for: components) {
            return "~/\(match.joined(separator: "/")) is protected in Explore. "
                + "You can inspect it, but files in it cannot be moved to Trash."
        }

        return nil
    }

    public func isProtected(_ url: URL, home: URL) -> Bool {
        protectionReason(for: url, home: home) != nil
    }

    // MARK: - Loading

    private struct PolicyDocument: Decodable {
        let schemaVersion: Int
        let neverTouch: [String]
        let exploreProtectedRoots: [String]
    }

    private static func validateList(
        _ paths: [String],
        name: String,
        allowEmpty: Bool
    ) throws {
        guard allowEmpty || !paths.isEmpty else {
            throw ProtectionPolicyError.invalid(detail: "\(name) must contain at least one path.")
        }

        var seen = Set<String>()
        for path in paths {
            try validate(relativePath: path)
            let key = path.lowercased()
            guard seen.insert(key).inserted else {
                throw ProtectionPolicyError.invalid(
                    detail: "Duplicate path in \(name): \(path)"
                )
            }
        }
    }

    private static func validate(relativePath raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProtectionPolicyError.invalid(detail: "A protected path is empty.")
        }
        guard trimmed == raw else {
            throw ProtectionPolicyError.invalid(
                detail: "Protected path '\(raw)' must not have leading or trailing whitespace."
            )
        }
        guard !raw.contains("\0") else {
            throw ProtectionPolicyError.invalid(
                detail: "Protected path '\(raw)' must not contain a NUL byte."
            )
        }
        guard !raw.hasPrefix("/") else {
            throw ProtectionPolicyError.invalid(
                detail: "Protected path '\(raw)' must be relative to the home folder."
            )
        }
        guard !raw.hasPrefix("~") else {
            throw ProtectionPolicyError.invalid(
                detail: "Protected path '\(raw)' must not start with a tilde."
            )
        }

        let components = raw
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty else {
            throw ProtectionPolicyError.invalid(detail: "A protected path is empty.")
        }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProtectionPolicyError.invalid(
                detail: "Protected path '\(raw)' must not contain '.' or '..' or empty components."
            )
        }
    }

    private static func normalize(_ paths: [String]) -> [[String]] {
        paths.compactMap { raw in
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("~/") {
                trimmed.removeFirst(2)
            } else if trimmed.hasPrefix("/") {
                trimmed.removeFirst()
            }

            let components = trimmed
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0 != "." }
            return components.isEmpty ? nil : components
        }
    }

    private static func matchingPrefix(
        in prefixes: [[String]],
        for components: [String]
    ) -> [String]? {
        var best: [String]?
        for prefix in prefixes where prefix.count <= components.count {
            let matches = prefix.indices.allSatisfy {
                ExplorePath.sameComponent(prefix[$0], components[$0])
            }
            guard matches else { continue }
            if prefix.count > (best?.count ?? 0) {
                best = prefix
            }
        }
        return best
    }
}

public enum ProtectionPolicyError: Error, Sendable, Equatable, LocalizedError {
    case missingBundledResource
    case unreadable(path: String, detail: String)
    case invalid(detail: String)
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .missingBundledResource:
            return "policy.json is missing from the app bundle."
        case .unreadable(let path, let detail):
            return "Could not read the protection policy at \(path): \(detail)"
        case .invalid(let detail):
            return "The protection policy is invalid: \(detail)"
        case .unsupportedSchemaVersion(let version):
            return "The protection policy schema version \(version) is not supported."
        }
    }
}
