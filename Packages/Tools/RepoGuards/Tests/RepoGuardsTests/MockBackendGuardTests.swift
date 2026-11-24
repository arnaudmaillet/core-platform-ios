import Foundation
import RepoGuards
import Testing

/// The mock backend stays out of the production app (#2391, epic #2366).
///
/// `CoreNetworkingMocks` (and `CoreRealtimeMocks`, and the mock media of
/// `MediaCoreFixtures` and `MediaPlaybackFixtures`, #2516) is linked by the
/// mock builds only: Debug, and Demo, the mock target built in Release. Their App
/// code compiles with `MOCK_BACKEND`. The production target links neither
/// module and compiles without the condition, so an App file naming a mock
/// outside `#if MOCK_BACKEND` breaks its build: "Unable to resolve module
/// dependency" in a clean build, "Undefined symbols" at link time where a
/// mock build shared its products folder. This guard says so in a sentence,
/// before any build.
///
/// `#if DEBUG` counts too: DEBUG builds only the mock target. Its code was
/// written for the mock, the dashboard and the QA launch arguments, long
/// before the production target existed.
struct MockBackendGuardTests {
    static let mockModules: Set<String> = [
        "CoreNetworkingMocks", "CoreRealtimeMocks", "MediaCoreFixtures", "MediaPlaybackFixtures"
    ]

    /// The folder of the App's mock half: every file in it is mock-only.
    static let mockFolder = "App/Composition/MockBackend"

    /// Whether `line` opens a condition that holds only in a mock build.
    static func isMockOnly(_ line: String) -> Bool {
        guard !line.contains("!") else { return false }
        return line.contains("MOCK_BACKEND") || line == "#if DEBUG"
    }

    /// The lines of `text` that import a mock module outside a mock-only
    /// `#if`. An `#else` branch is not mock-only, whatever its `#if` said.
    static func importsOutsideMockBuilds(_ text: String) -> [Int] {
        var conditions: [Bool] = []
        var found: [Int] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                conditions.append(isMockOnly(line))
            } else if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                if !conditions.isEmpty { conditions[conditions.count - 1] = false }
            } else if line == "#endif" {
                _ = conditions.popLast()
            } else if line.hasPrefix("import "),
                      mockModules.contains(String(line.dropFirst("import ".count))),
                      !conditions.contains(true) {
                found.append(index + 1)
            }
        }
        return found
    }

    /// Whether `text`'s code, past its comments, opens with an
    /// `#if MOCK_BACKEND…` and ends with `#endif`: the whole file, imports
    /// included, is gone from the production build.
    static func isMockOnlyFile(_ text: String) -> Bool {
        let code = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        guard let first = code.first, let last = code.last else { return false }
        return first.hasPrefix("#if MOCK_BACKEND") && !first.contains("!") && last == "#endif"
    }

    static func appSources() throws -> [String] {
        let app = RepoRoot.url.appendingPathComponent("App")
        return try #require(FileManager.default.enumerator(atPath: app.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
    }

    @Test func theAppImportsTheMocksOnlyInMockBuilds() throws {
        let files = try Self.appSources()
        #expect(!files.isEmpty, "no sources under App")
        let app = RepoRoot.url.appendingPathComponent("App")
        var problems: [String] = []
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            let lines = Self.importsOutsideMockBuilds(text)
            if !lines.isEmpty { problems.append("App/\(file):\(lines)") }
        }
        #expect(problems.isEmpty, """
            a mock module imported outside #if MOCK_BACKEND: the production target does not link it. \
            Put the code in \(Self.mockFolder) or behind #if MOCK_BACKEND:
            \(problems.joined(separator: "\n"))
            """)
    }

    @Test func everyMockBackendFileIsWrappedWhole() throws {
        let folder = RepoRoot.url.appendingPathComponent(Self.mockFolder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty, "no sources under \(Self.mockFolder)")
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(Self.isMockOnlyFile(text), "\(file) is not wrapped in #if MOCK_BACKEND … #endif")
        }
    }

    @Test func theImportPatternSeesAProductionImport() {
        #expect(Self.importsOutsideMockBuilds("#if MOCK_BACKEND\nimport CoreNetworkingMocks\n#endif\n").isEmpty)
        #expect(Self.importsOutsideMockBuilds("#if DEBUG\nimport CoreRealtimeMocks\n#endif\n").isEmpty)
        #expect(Self.importsOutsideMockBuilds("#if MOCK_BACKEND && DEBUG\nimport CoreNetworkingMocks\n#endif\n").isEmpty)
        #expect(Self.importsOutsideMockBuilds("import UIKit\nimport CoreNetworkingMocks\n") == [2])
        #expect(Self.importsOutsideMockBuilds("#if MOCK_BACKEND\nimport A\n#else\nimport CoreNetworkingMocks\n#endif\n") == [4])
        #expect(Self.importsOutsideMockBuilds("#if !MOCK_BACKEND\nimport CoreNetworkingMocks\n#endif\n") == [2])
        #expect(Self.importsOutsideMockBuilds("#if canImport(X)\nimport CoreRealtimeMocks\n#endif\n") == [2])
        #expect(Self.importsOutsideMockBuilds("import CoreNetworking\n").isEmpty)
    }

    @Test func theFilePatternSeesAnUnguardedFile() {
        #expect(Self.isMockOnlyFile("#if MOCK_BACKEND\nimport UIKit\nfinal class A {}\n#endif\n"))
        #expect(Self.isMockOnlyFile("// A note.\n#if MOCK_BACKEND && DEBUG\nimport UIKit\n#endif\n"))
        #expect(!Self.isMockOnlyFile("import UIKit\n#if MOCK_BACKEND\nfinal class A {}\n#endif\n"))
        #expect(!Self.isMockOnlyFile("#if MOCK_BACKEND\nfinal class A {}\n#endif\nfinal class B {}\n"))
        #expect(!Self.isMockOnlyFile("#if !MOCK_BACKEND\nfinal class A {}\n#endif\n"))
    }
}
