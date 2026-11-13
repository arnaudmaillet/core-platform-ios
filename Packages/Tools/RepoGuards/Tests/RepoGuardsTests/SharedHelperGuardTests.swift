import Foundation
import RepoGuards
import Testing

/// One implementation per helper (#2390, `dev/CONVENTIONS.md`): a second copy
/// fails here, so a fix in one never misses the other.
///
/// - A blur whose strength is a fraction of its material (a paused animator
///   whose `fractionComplete` drives a `UIBlurEffect`) is DesignSystem's
///   `ProgressBlurView`. Feed carried a copy until #2390.
struct SharedHelperGuardTests {
    /// Where the strength blur is made.
    static let progressBlur = "Packages/Core/DesignSystem/Sources/DesignSystem/Components/ProgressBlurView.swift"

    /// The non-test Swift sources under `App/` and `Packages/`, relative to the
    /// repository's root.
    static func sources() throws -> [String] {
        let root = RepoRoot.url
        var found: [String] = []
        for top in ["App", "Packages"] {
            let base = root.appendingPathComponent(top)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let path as String in walker
            where path.hasSuffix(".swift") && !path.contains("/Tests/") && !path.contains("/.build/") {
                found.append("\(top)/\(path)")
            }
        }
        return found
    }

    /// Whether `text` drives a blur's strength with an animator's fraction.
    static func makesAStrengthBlur(_ text: String) -> Bool {
        text.contains("fractionComplete") && text.contains("UIBlurEffect(")
    }

    @Test func theStrengthBlurIsProgressBlurViewAlone() throws {
        let root = RepoRoot.url
        var copies: [String] = []
        for file in try Self.sources() where file != Self.progressBlur {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            if Self.makesAStrengthBlur(text) { copies.append(file) }
        }
        #expect(copies.isEmpty, "a strength blur outside ProgressBlurView: \(copies)")
    }

    @Test func thePatternSeesACopy() {
        #expect(Self.makesAStrengthBlur("animator.fractionComplete = x\nself.effect = UIBlurEffect(style: s)"))
        #expect(!Self.makesAStrengthBlur("self.effect = UIBlurEffect(style: s)"))
    }
}
