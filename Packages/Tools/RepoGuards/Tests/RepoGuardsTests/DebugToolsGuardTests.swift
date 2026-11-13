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

    @Test func thePatternSeesAnUnguardedFile() {
        #expect(Self.isDebugOnly("import UIKit\n\n#if DEBUG\nfinal class A {}\n#endif\n"))
        #expect(!Self.isDebugOnly("import UIKit\nfinal class A {}\n"))
        #expect(!Self.isDebugOnly("import UIKit\n#if DEBUG\nfinal class A {}\n#endif\nfinal class B {}\n"))
    }
}
