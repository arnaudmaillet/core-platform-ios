import Foundation
import RepoGuards
import Testing

/// DebugTools compiles to nothing in Release (#2386): each of its sources
/// opens with `#if DEBUG` after its imports and closes with `#endif`. A file
/// added without the guard would put a debug tool in the shipped app.
struct DebugToolsGuardTests {
    static let sources = "Packages/Core/DebugTools/Sources/DebugTools"

    /// Whether `text`'s code, past its imports and comments, opens with
    /// `#if DEBUG` and ends with `#endif`.
    static func isDebugOnly(_ text: String) -> Bool {
        let code = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("import ") }
        return code.first == "#if DEBUG" && code.last == "#endif"
    }

    @Test func everyDebugToolCompilesToNothingInRelease() throws {
        let folder = RepoRoot.url.appendingPathComponent(Self.sources)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty, "no sources under \(Self.sources)")
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            #expect(Self.isDebugOnly(text), "\(file) is not wrapped in #if DEBUG … #endif")
        }
    }

    /// The app reaches DebugTools only from DEBUG code (#2386, the owner's
    /// choice of 2026-11-18): the product stays linked, compiled empty in
    /// Release, and no Release source may name it. An `import DebugTools`
    /// outside `#if DEBUG` is where a debug tool would slip into the shipped
    /// app first.
    static func importsOutsideDebug(_ text: String) -> [Int] {
        var conditions: [Bool] = []
        var found: [Int] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                conditions.append(line == "#if DEBUG")
            } else if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                if !conditions.isEmpty { conditions[conditions.count - 1] = false }
            } else if line == "#endif" {
                _ = conditions.popLast()
            } else if line == "import DebugTools", !conditions.contains(true) {
                found.append(index + 1)
            }
        }
        return found
    }

    @Test func theAppImportsDebugToolsOnlyInDebug() throws {
        let app = RepoRoot.url.appendingPathComponent("App")
        let files = try #require(FileManager.default.enumerator(atPath: app.path))
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty, "no sources under App")
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            let lines = Self.importsOutsideDebug(text)
            #expect(lines.isEmpty, "App/\(file):\(lines) imports DebugTools outside #if DEBUG")
        }
    }

    @Test func theImportPatternSeesAReleaseImport() {
        #expect(Self.importsOutsideDebug("#if DEBUG\nimport DebugTools\n#endif\n").isEmpty)
        #expect(Self.importsOutsideDebug("import UIKit\nimport DebugTools\n") == [2])
        #expect(Self.importsOutsideDebug("#if DEBUG\nimport A\n#else\nimport DebugTools\n#endif\n") == [4])
        #expect(Self.importsOutsideDebug("#if canImport(X)\nimport DebugTools\n#endif\n") == [2])
    }

    @Test func thePatternSeesAnUnguardedFile() {
        #expect(Self.isDebugOnly("import UIKit\n\n#if DEBUG\nfinal class A {}\n#endif\n"))
        #expect(!Self.isDebugOnly("import UIKit\nfinal class A {}\n"))
        #expect(!Self.isDebugOnly("import UIKit\n#if DEBUG\nfinal class A {}\n#endif\nfinal class B {}\n"))
    }
}
