import Foundation
import Testing
@testable import MkBarCore

@Suite("Explore protection policy")
struct ProtectionPolicyTests {
    @Test func repoPolicyProtectsRegistryPathsAndLibrary() throws {
        let policy = try ProtectionPolicy.load(from: repoPolicyURL)

        #expect(policy.neverTouch.contains("Documents"))
        #expect(policy.neverTouch.contains("Library/Containers"))
        #expect(policy.exploreProtectedRoots == ["Library"])

        let home = URL(fileURLWithPath: "/Users/tester")
        let documents = home.appendingPathComponent("Documents/secret.txt")
        let library = home.appendingPathComponent("Library/Caches/cache.bin")
        let containers = home.appendingPathComponent("Library/Containers/App/data")

        let documentsReason = try #require(
            policy.protectionReason(for: documents, home: home)
        )
        #expect(documentsReason.contains("never-touch"))

        let libraryReason = try #require(
            policy.protectionReason(for: library, home: home)
        )
        #expect(libraryReason.contains("protected in Explore"))

        let containersReason = try #require(
            policy.protectionReason(for: containers, home: home)
        )
        #expect(containersReason.contains("Library/Containers") || containersReason.contains("Library"))
    }

    @Test func relativeChecksAreCaseInsensitiveAndComponentBounded() {
        let policy = makeExplorePolicy()
        let home = URL(fileURLWithPath: "/Users/tester")

        #expect(policy.isProtected(home.appendingPathComponent("documents/notes.txt"), home: home))
        #expect(policy.isProtected(home.appendingPathComponent(".SSH/id_ed25519"), home: home))
        #expect(policy.isProtected(home.appendingPathComponent("library/logs/x"), home: home))
        #expect(policy.isProtected(home.appendingPathComponent("Library/Containers/x"), home: home))

        #expect(!policy.isProtected(home.appendingPathComponent("Documents2/notes.txt"), home: home))
        #expect(!policy.isProtected(home.appendingPathComponent("Library2/logs/x"), home: home))
        #expect(!policy.isProtected(home.appendingPathComponent("Projects/notes.txt"), home: home))
        #expect(
            policy.protectionReason(
                for: home.appendingPathComponent("Projects/x"),
                home: home
            ) == nil
        )
    }

    @Test func missingPolicyFailsClosed() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-policy-\(UUID().uuidString).json")

        do {
            _ = try ProtectionPolicy.load(from: missing)
            Issue.record("Expected a missing policy to throw")
        } catch let error as ProtectionPolicyError {
            guard case .unreadable = error else {
                Issue.record("Expected unreadable, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func emptyPolicyAndMalformedJSONFailClosed() throws {
        let empty = try temporaryExplorePolicyFile(
            #"{"schemaVersion":1,"neverTouch":[],"exploreProtectedRoots":["Library"]}"#
        )
        defer { try? FileManager.default.removeItem(at: empty) }

        do {
            _ = try ProtectionPolicy.load(from: empty)
            Issue.record("Expected an empty neverTouch list to throw")
        } catch let error as ProtectionPolicyError {
            guard case .invalid = error else {
                Issue.record("Expected invalid, got \(error)")
                return
            }
        }
        catch {
            Issue.record("Unexpected error: \(error)")
        }

        let malformed = try temporaryExplorePolicyFile("{not json")
        defer { try? FileManager.default.removeItem(at: malformed) }

        do {
            _ = try ProtectionPolicy.load(from: malformed)
            Issue.record("Expected malformed JSON to throw")
        } catch let error as ProtectionPolicyError {
            guard case .invalid = error else {
                Issue.record("Expected invalid, got \(error)")
                return
            }
        }
        catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func emptyExploreProtectedRootsIsAllowedForSharedPolicyCompatibility() throws {
        let emptyRoots = try temporaryExplorePolicyFile(
            #"{"schemaVersion":1,"neverTouch":["Documents"],"exploreProtectedRoots":[]}"#
        )
        defer { try? FileManager.default.removeItem(at: emptyRoots) }

        let policy = try ProtectionPolicy.load(from: emptyRoots)
        #expect(policy.neverTouch == ["Documents"])
        #expect(policy.exploreProtectedRoots.isEmpty)
    }

    @Test func unsupportedSchemaAndMissingProtectedRootsFailClosed() throws {
        let unsupported = try temporaryExplorePolicyFile(
            #"{"schemaVersion":2,"neverTouch":["Documents"],"exploreProtectedRoots":["Library"]}"#
        )
        defer { try? FileManager.default.removeItem(at: unsupported) }

        do {
            _ = try ProtectionPolicy.load(from: unsupported)
            Issue.record("Expected an unsupported schema to throw")
        } catch let error as ProtectionPolicyError {
            guard case .unsupportedSchemaVersion(2) = error else {
                Issue.record("Expected unsupportedSchemaVersion(2), got \(error)")
                return
            }
        }
        catch {
            Issue.record("Unexpected error: \(error)")
        }

        let noRoots = try temporaryExplorePolicyFile(
            #"{"schemaVersion":1,"neverTouch":["Documents"]}"#
        )
        defer { try? FileManager.default.removeItem(at: noRoots) }

        do {
            _ = try ProtectionPolicy.load(from: noRoots)
            Issue.record("Expected missing exploreProtectedRoots to throw")
        } catch is ProtectionPolicyError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private var repoPolicyURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("policy.json")
    }
}
