import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#2047): every `ViewerScoped` cache hears of a viewer
/// change. `AppContainer.observeViewerTransitions` calls the ones in its
/// `scoped` list, and nothing else does: `FeedRepository` conformed to
/// nothing and was in no list, so a member's posts were served to the guest
/// after a sign-out. Every type under `App/` and `Packages/` (tests
/// excluded) that conforms is in that list, named after its type
/// (`CommentsRepository` → `commentsRepository`), or is named below with the
/// reason it is not.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct ViewerScopedGuardTests {
    /// Type name → why it is not in `AppContainer`'s list.
    static let calledElsewhere: [String: String] = [:]

    /// Every conformer's type name, in `text`.
    static func conformers(in text: String) -> Set<String> {
        let pattern = #"(?:extension|class|actor|struct)\s+(\w+)\b[^{]*:\s*[^{]*\bViewerScoped\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The identifiers in `AppContainer`'s `scoped` list, or nil when the
    /// list cannot be found.
    static func scopedList(in text: String) -> Set<String>? {
        guard let start = text.range(of: "let scoped: [any ViewerScoped] = ["),
              let end = text.range(of: "]", range: start.upperBound..<text.endIndex)
        else { return nil }
        // Line by line, comments dropped; one step per statement, so the
        // type-checker of Xcode 26 (CI) never has to infer a chain.
        var names: Set<String> = []
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let code: String = line.components(separatedBy: "//")[0]
            for word in code.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) {
                names.insert(String(word))
            }
        }
        return names
    }

    static func propertyName(of type: String) -> String {
        type.prefix(1).lowercased() + type.dropFirst()
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FeedTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Feed
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Every source file's text, tests excluded.
    private static func sources() -> String {
        var texts: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                texts.append(text)
            }
        }
        return texts.joined(separator: "\n")
    }

    @Test func theGuardReadsConformersAndTheList() {
        let text = """
        extension ARepository: ViewerScoped {
        public actor AStore: Providing, ViewerScoped {
        final class NotOne: Providing {}
        let scoped: [any ViewerScoped] = [
            aRepository, // a comment naming notListed
            // notListedEither
            aStore
        ]
        """
        #expect(Self.conformers(in: text) == ["ARepository", "AStore"])
        #expect(Self.scopedList(in: text) == ["aRepository", "aStore"])
        #expect(Self.propertyName(of: "ARepository") == "aRepository")
    }

    @Test func everyViewerScopedCacheIsInTheContainersList() throws {
        let container = try String(contentsOf: Self.root.appendingPathComponent("App/AppContainer.swift"), encoding: .utf8)
        let listed = try #require(Self.scopedList(in: container), "AppContainer's `scoped` list was not found")
        let found = Self.conformers(in: Self.sources())
        // The guard sees the conformers it was written against.
        #expect(found.isSuperset(of: ["FeedRepository", "CommentsRepository", "NotificationsRepository"]))

        let missing = found
            .filter { Self.calledElsewhere[$0] == nil && !listed.contains(Self.propertyName(of: $0)) }
            .sorted()
        #expect(missing.isEmpty, "ViewerScoped but not in AppContainer.observeViewerTransitions' `scoped` list: \(missing)")
    }
}
