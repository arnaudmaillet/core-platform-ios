import Foundation
import RepoGuards
import Testing

/// A FEATURE'S BUILDER NAMES WHAT IT NEEDS: NO CAPABILITY CASTS, NO
/// `= nil` DEFAULTS (#2375, epic #2366).
///
/// A feature's entry point (`*FeatureBuilder`, `*Assembly` under
/// `Packages/Features`) takes its collaborators as a typed `Dependencies`.
/// A builder that asked a repository at run time what else it could do
/// (`repository as? any GroupChatServicing`) compiled when the composition
/// root handed one that couldn't, and the feature quietly went missing; a
/// parameter defaulting to `nil` compiled when the root forgot it. A
/// capability is typed into the dependency instead (`any A & B`), and a
/// dependency that can be absent is `Optional` with no default, so the root
/// writes `nil` itself.
///
/// ⚠️ A FAILURE HERE: type the dependency as the composition it needs, or
/// remove the default and pass the value (or `nil`) at the call site. A
/// cast of a view controller to a transition role it may play is not a
/// dependency: add the role to `viewControllerRoles`.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct BuilderDependenciesGuardTests {
    /// Run-time role queries on view controllers — which screen a
    /// transition lands on — not dependency wiring.
    static let viewControllerRoles: Set<String> = [
        "ZoomTransitionDestination", "SnapFeedSettleReporting", "FeedBeneathLanding"
    ]

    /// The builders whose init still defaults collaborators to `nil`: not
    /// converted to a `Dependencies` yet. Only ever shrinks.
    static let notConvertedYet: Set<String> = [
        "AuthFeatureBuilder.swift", "MapsFeatureBuilder.swift",
        "NotificationsFeatureBuilder.swift", "SearchFeatureBuilder.swift"
    ]

    /// Every feature entry point, as a path under `Packages/Features`.
    static func builderFiles() throws -> [String] {
        let features = RepoRoot.url.appendingPathComponent("Packages/Features")
        guard let enumerator = FileManager.default.enumerator(atPath: features.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: features.path])
        }
        return enumerator
            .compactMap { $0 as? String }
            .filter { $0.contains("/Sources/") }
            .filter { $0.hasSuffix("FeatureBuilder.swift") || $0.hasSuffix("Assembly.swift") }
            .sorted()
    }

    static func text(of file: String) throws -> String {
        let url = RepoRoot.url.appendingPathComponent("Packages/Features").appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `line` without its `//` comment.
    static func code(_ line: Substring) -> Substring {
        guard let range = line.range(of: "//") else { return line }
        return line[..<range.lowerBound]
    }

    /// The protocols `text` casts to (`as? any P`, `as! any P`), with their
    /// lines; comments are not code.
    static func casts(in text: String) -> [(line: Int, type: String)] {
        let pattern = /as[?!]\s*any\s+(\w+)/
        var found: [(Int, String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for match in code(line).matches(of: pattern) {
                found.append((index + 1, String(match.output.1)))
            }
        }
        return found
    }

    /// The lines of `text`'s initializers' parameter lists that default a
    /// parameter to `nil`.
    static func nilDefaults(in text: String) -> [Int] {
        let characters = Array(text)
        var lines: [Int] = []
        var searchFrom = text.startIndex
        while let match = text[searchFrom...].firstMatch(of: /\binit\s*\(/) {
            var depth = 1
            var index = text.distance(from: text.startIndex, to: match.range.upperBound)
            let start = index
            while depth > 0, index < characters.count {
                if characters[index] == "(" { depth += 1 } else if characters[index] == ")" { depth -= 1 }
                index += 1
            }
            let firstLine = text[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
            let parameters = String(characters[start..<max(start, index - 1)])
            for (offset, line) in parameters.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where code(line).contains(/=\s*nil\b/) {
                lines.append(firstLine + offset)
            }
            searchFrom = text.index(text.startIndex, offsetBy: index)
        }
        return lines
    }

    @Test func buildersCastNoDependencyToACapability() throws {
        var problems: [String] = []
        for file in try Self.builderFiles() {
            for (line, type) in Self.casts(in: try Self.text(of: file)) where !Self.viewControllerRoles.contains(type) {
                problems.append("Packages/Features/\(file):\(line) casts to \(type)")
            }
        }
        let found = problems.joined(separator: "\n")
        #expect(problems.isEmpty, "type the dependency as the composition it needs:\n\(found)")
    }

    @Test func buildersDefaultNoCollaboratorToNil() throws {
        var problems: [String] = []
        for file in try Self.builderFiles() where !Self.notConvertedYet.contains((file as NSString).lastPathComponent) {
            for line in Self.nilDefaults(in: try Self.text(of: file)) {
                problems.append("Packages/Features/\(file):\(line) defaults a parameter to nil")
            }
        }
        let found = problems.joined(separator: "\n")
        #expect(problems.isEmpty, "remove the default; the call site passes the value or nil:\n\(found)")
    }

    /// The list of builders still to convert only shrinks: one converted
    /// leaves it.
    @Test func theBuildersStillToConvertStillDefaultToNil() throws {
        let files = try Self.builderFiles()
        for name in Self.notConvertedYet {
            let file = try #require(
                files.first(where: { ($0 as NSString).lastPathComponent == name }), "\(name) is gone"
            )
            let defaults = Self.nilDefaults(in: try Self.text(of: file))
            #expect(!defaults.isEmpty, "\(name) is converted: take it off the list")
        }
    }

    /// The scan can't pass by reading nothing, and the patterns see what
    /// they look for.
    @Test func theScanReadsTheBuildersAndSeesCastsAndDefaults() throws {
        let names = try Self.builderFiles().map { ($0 as NSString).lastPathComponent }
        #expect(Set(names).isSuperset(of: [
            "ChatFeatureBuilder.swift", "FeedFeatureBuilder.swift", "ProfileFeatureBuilder.swift",
            "PlaceFeatureBuilder.swift", "SettingsAssembly.swift"
        ]), "read \(names)")
        let sample = """
        public init(
            repository: any ChatProviding,
            people: (any PeopleDirectoryProviding)? = nil,
            router: any Router // = nil once
        ) {
            groups = repository as? any GroupChatServicing
            // repository as! any ProfileChannelsReading
            let feed = destination as? any SnapFeedSettleReporting
        }
        func open(beneath: UIViewController? = nil) {}
        """
        #expect(Self.casts(in: sample).map(\.type) == ["GroupChatServicing", "SnapFeedSettleReporting"])
        #expect(Self.casts(in: sample).map(\.line) == [6, 8])
        #expect(Self.nilDefaults(in: sample) == [3])
    }
}
