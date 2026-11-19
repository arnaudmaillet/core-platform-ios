import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#2376): a store that holds the viewer's data is
/// built ONCE, by the composition root, and handed to whoever needs it — never
/// reached through a global. A `shared` instance hid who depended on it, and
/// one keyed by nothing (`VoicePlayedStore`'s played ids) read the last
/// viewer's data for the next one.
///
/// For every type named in `viewerTypes`, under `App/` and `Packages/` (tests
/// excluded): no `static let shared = <Type>(…)` declaration, no
/// `<Type>.shared`, and no `<Type> = .shared` default value.
///
/// And ONE `StorageScope` (#2376): the stores observe their scope's change
/// notification with THEIR scope as the object, so a store built over a
/// second scope would never follow the viewer, and nothing would visibly
/// fail. `StorageScope(` appears once in production code, in
/// `App/Composition/AppContainer.swift`, and no `scope: StorageScope = …`
/// default lets a store pick its own.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct ViewerStoreGuardTests {
    /// The per-viewer stores.
    static let viewerTypes: [String] = [
        "StorageScope",
        "PostBookmarkStore",
        "PostViewHistoryStore",
        "SectionPresenceStore",
        "TeenProtections",
        "UnavailablePosts",
        "VoicePlayedStore",
        "PublishedVideoFiles",
        "WalletStore",
        "LikeOutbox",
        "PostDraftStore",
        "SavedSoundStore",
        "MapDockedPlacesStore",
        "MapFavoritesStore",
        "MapPlaceFollowStore",
    ]

    /// The one file that builds the app's `StorageScope`.
    static let scopeOwner = "App/Composition/AppContainer.swift"

    /// `"<file path relative to the repository>: <type>"` → why that file may
    /// still name the type's `shared`. Empty, and meant to stay so.
    static let allowed: [String: String] = [:]

    /// `text` without its comments (line comments and doc comments), so a
    /// comment that tells the story of a removed `shared` is not a use.
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
                return line.components(separatedBy: " //")[0]
            }
            .joined(separator: "\n")
    }

    /// Whether `code` declares a `shared` instance of `type`.
    static func declaresShared(_ type: String, in code: String) -> Bool {
        let pattern = #"static\s+(?:let|var)\s+shared\s*(?::\s*"# + type + #"\s*)?=\s*"# + type + #"\s*\("#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether `code` reaches `type`'s `shared`: `<Type>.shared`, or a value
    /// typed as the type that defaults to `.shared`.
    static func usesShared(_ type: String, in code: String) -> Bool {
        let reference = #"\b"# + type + #"\.shared\b"#
        let defaultValue = #"\b"# + type + #"\??\s*=\s*\.shared\b"#
        return code.range(of: reference, options: .regularExpression) != nil
            || code.range(of: defaultValue, options: .regularExpression) != nil
    }

    /// How many times `code` builds a `StorageScope`.
    static func scopeConstructions(in code: String) -> Int {
        let regex = try! NSRegularExpression(pattern: #"\bStorageScope\s*\("#)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// Whether `code` gives a `StorageScope` parameter a default value.
    static func defaultsAScope(in code: String) -> Bool {
        code.range(of: #":\s*StorageScope\s*=\s*"#, options: .regularExpression) != nil
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RepoGuardsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RepoGuards
            .deletingLastPathComponent() // Tools
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Every source file under `App/` and `Packages/`, tests excluded: its
    /// path from the repository root, and its code (comments dropped).
    static func sources() -> [(path: String, code: String)] {
        var files: [(path: String, code: String)] = []
        let rootPath = root.path + "/"
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
                files.append((relative, code(text)))
            }
        }
        return files
    }

    @Test func theGuardReadsDeclarationsAndUses() {
        let text = """
        public final class AStore {
            public static let shared = AStore()
            static let sharedKey = "a"
        }
        /// `AStore.shared` was the app's one.
        var store: AStore = .shared
        let other = AStore.shared // a comment naming AStore.shared
        init(store: AStore? = .shared) {}
        let fine = AStore(defaults: .standard)
        init(scope: StorageScope = .shared) {}
        let scope = StorageScope()
        let owner = StorageScope.Owner.guest
        """
        let code = Self.code(text)
        #expect(Self.defaultsAScope(in: code))
        #expect(!Self.defaultsAScope(in: "init(scope: StorageScope) {}"))
        #expect(Self.scopeConstructions(in: code) == 1)
        #expect(Self.scopeConstructions(in: Self.code("/// `StorageScope(owner:)` in a doc comment")) == 0)
        #expect(Self.declaresShared("AStore", in: code))
        #expect(Self.usesShared("AStore", in: code))
        #expect(!Self.declaresShared("AStore", in: "static let sharedKey = AStore.key"))
        #expect(!Self.usesShared("AStore", in: Self.code("/// `AStore.shared` was the app's one.")))
        #expect(!Self.usesShared("AStore", in: "let fine = AStore(defaults: .standard)"))
        #expect(Self.usesShared("AStore", in: "init(store: AStore? = .shared) {}"))
    }

    @Test func noViewerStoreIsReachedThroughAGlobal() {
        let files = Self.sources()
        // The guard sees the files it was written against.
        #expect(files.contains { $0.path.hasSuffix("CoreStorage/SectionPresenceStore.swift") })

        var found: [String] = []
        for file in files {
            for type in Self.viewerTypes where Self.allowed["\(file.path): \(type)"] == nil {
                if Self.usesShared(type, in: file.code) { found.append("\(file.path): \(type).shared") }
                if Self.declaresShared(type, in: file.code) { found.append("\(file.path): static shared \(type)") }
            }
        }
        #expect(found.isEmpty, "A per-viewer store reached through a global — hand it in from AppContainer: \(found)")
    }

    @Test func theAppBuildsOneStorageScope() throws {
        let files = Self.sources()
        let owner = try #require(files.first { $0.path == Self.scopeOwner }, "\(Self.scopeOwner) was not found")
        #expect(Self.scopeConstructions(in: owner.code) == 1, "AppContainer builds the app's one StorageScope, once")

        let elsewhere = files
            .filter { $0.path != Self.scopeOwner && Self.scopeConstructions(in: $0.code) > 0 }
            .map(\.path)
        #expect(elsewhere.isEmpty, "A StorageScope built outside AppContainer never follows the viewer: \(elsewhere)")

        let defaulted = files.filter { Self.defaultsAScope(in: $0.code) }.map(\.path)
        #expect(defaulted.isEmpty, "A store's scope is handed in, never defaulted: \(defaulted)")
    }
}
