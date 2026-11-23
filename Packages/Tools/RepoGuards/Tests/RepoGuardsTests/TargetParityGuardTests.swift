import Foundation
import RepoGuards
import Testing

/// THE TWO APP TARGETS (#2391, epic #2366), read from the project file:
///
/// - `core-platform-ios`, the mock backend's builds: Debug, and Demo (the
///   target in Release). It links the mocks and compiles with `MOCK_BACKEND`.
/// - `core-platform-ios-production`, the production build: Release only, the
///   real backend only — no `CoreNetworkingMocks`, no `CoreRealtimeMocks`, no
///   mock media (`MediaCoreFixtures`, `MediaPlaybackFixtures`, #2516), and no
///   `DebugTools` (DEBUG-only, and the target never builds Debug).
///
/// One `App` folder, so the two must link the same packages but those five:
/// a package added to one target alone breaks the other's build — at link
/// time when they share a products folder, which reads far worse than this.
struct TargetParityGuardTests {
    static let project = "core-platform-ios.xcodeproj/project.pbxproj"
    static let mockTarget = "core-platform-ios"
    static let productionTarget = "core-platform-ios-production"
    /// What only the mock target links.
    static let mockOnly: Set<String> = [
        "CoreNetworkingMocks", "CoreRealtimeMocks", "MediaCoreFixtures", "MediaPlaybackFixtures", "DebugTools"
    ]

    static func pbxproj() throws -> String {
        try String(contentsOf: RepoRoot.url.appendingPathComponent(project), encoding: .utf8)
    }

    /// The body of the native target named `name`, or nil.
    static func targetBody(_ name: String, in text: String) -> Substring? {
        let quoted = name.contains("-") ? "\"\(name)\"" : name
        let marker = "\t\t\tisa = PBXNativeTarget;"
        var rest = text[...]
        while let start = rest.range(of: marker) {
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "\n\t\t};") else { return nil }
            let body = after[..<end.lowerBound]
            if body.contains("\n\t\t\tname = \(quoted);") { return body }
            rest = after[end.upperBound...]
        }
        return nil
    }

    /// The package products a target links, by name: its Frameworks phase.
    /// Not `packageProductDependencies`, which the mock target's list
    /// misses eight of (Profile, Search, Chat, Notifications and their
    /// interfaces) — Xcode links what the phase names.
    static func linkedProducts(of body: Substring, in text: String) throws -> Set<String> {
        let phase = try Regex(#"\n\t\t\t\t(\w+) /\* Frameworks \*/,"#, as: (Substring, Substring).self)
        let product = try Regex(#"/\* (\w+) in Frameworks \*/"#, as: (Substring, Substring).self)
        guard let id = body.firstMatch(of: phase)?.output.1,
              let start = text.range(of: "\n\t\t\(id) /* Frameworks */ = {"),
              let end = text[start.upperBound...].range(of: "\n\t\t};")
        else { return [] }
        return Set(text[start.upperBound..<end.lowerBound].matches(of: product).map { String($0.output.1) })
    }

    /// The build settings blocks of a target's configurations.
    static func configurations(of body: Substring, in text: String) throws -> [Substring] {
        let listID = try Regex(#"buildConfigurationList = (\w+) "#, as: (Substring, Substring).self)
        let entry = try Regex(#"\n\t\t\t\t(\w+) /\* \w+ \*/"#, as: (Substring, Substring).self)
        guard let list = body.firstMatch(of: listID)?.output.1,
              let listStart = text.range(of: "\n\t\t\(list) /* Build configuration list"),
              let listEnd = text[listStart.upperBound...].range(of: "\n\t\t};")
        else { return [] }
        let ids = text[listStart.upperBound..<listEnd.lowerBound].matches(of: entry).map(\.output.1)
        return ids.compactMap { id in
            guard let start = text.range(of: "\n\t\t\(id) /* "),
                  let end = text[start.upperBound...].range(of: "\n\t\t};") else { return nil }
            return text[start.upperBound..<end.lowerBound]
        }
    }

    @Test func theTargetsLinkTheSamePackagesButTheMocks() throws {
        let text = try Self.pbxproj()
        let mock = try #require(Self.targetBody(Self.mockTarget, in: text), "no \(Self.mockTarget) target")
        let production = try #require(Self.targetBody(Self.productionTarget, in: text), "no \(Self.productionTarget) target")
        let mockProducts = try Self.linkedProducts(of: mock, in: text)
        let productionProducts = try Self.linkedProducts(of: production, in: text)
        #expect(mockProducts.count > 10, "could not read \(Self.mockTarget)'s packages")
        #expect(productionProducts.isDisjoint(with: Self.mockOnly),
                "\(Self.productionTarget) links \(productionProducts.intersection(Self.mockOnly).sorted()): the production app ships no mock")
        #expect(productionProducts.subtracting(mockProducts).isEmpty,
                "only \(Self.productionTarget) links \(productionProducts.subtracting(mockProducts).sorted()): add them to \(Self.mockTarget) too")
        #expect(mockProducts.subtracting(productionProducts) == Self.mockOnly,
                "only \(Self.mockTarget) links \(mockProducts.subtracting(productionProducts).subtracting(Self.mockOnly).sorted()): add them to \(Self.productionTarget) too")
    }

    @Test func onlyTheMockTargetCompilesTheMockBackend() throws {
        let text = try Self.pbxproj()
        let mock = try #require(Self.targetBody(Self.mockTarget, in: text))
        let production = try #require(Self.targetBody(Self.productionTarget, in: text))
        let mockConfigurations = try Self.configurations(of: mock, in: text)
        let productionConfigurations = try Self.configurations(of: production, in: text)
        #expect(mockConfigurations.count == 2 && productionConfigurations.count == 2)
        for configuration in mockConfigurations {
            #expect(configuration.contains("MOCK_BACKEND"), "a \(Self.mockTarget) configuration without MOCK_BACKEND")
        }
        for configuration in productionConfigurations {
            #expect(!configuration.contains("MOCK_BACKEND"), "a \(Self.productionTarget) configuration with MOCK_BACKEND")
        }
    }

    @Test func theReadersSeeAProjectsShape() throws {
        // The leading empty line: every block opens on a new line.
        let text = """

        \t\tF /* Frameworks */ = {
        \t\t\tfiles = (
        \t\t\t\tB1 /* Feed in Frameworks */,
        \t\t\t\tB2 /* CoreNetworkingMocks in Frameworks */,
        \t\t\t);
        \t\t};
        \t\tA /* app */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = L /* Build configuration list for PBXNativeTarget "app" */;
        \t\t\tbuildPhases = (
        \t\t\t\tS /* Sources */,
        \t\t\t\tF /* Frameworks */,
        \t\t\t);
        \t\t\tname = "app-two";
        \t\t\tpackageProductDependencies = (
        \t\t\t\tP1 /* Feed */,
        \t\t\t);
        \t\t};
        \t\tL /* Build configuration list for PBXNativeTarget "app" */ = {
        \t\t\tbuildConfigurations = (
        \t\t\t\tC1 /* Debug */,
        \t\t\t);
        \t\t};
        \t\tC1 /* Debug */ = {
        \t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "MOCK_BACKEND";
        \t\t};
        """
        let body = try #require(Self.targetBody("app-two", in: text))
        #expect(try Self.linkedProducts(of: body, in: text) == ["Feed", "CoreNetworkingMocks"])
        let configurations = try Self.configurations(of: body, in: text)
        #expect(configurations.count == 1)
        #expect(configurations.first?.contains("MOCK_BACKEND") == true)
        #expect(Self.targetBody("app", in: text) == nil)
    }
}
