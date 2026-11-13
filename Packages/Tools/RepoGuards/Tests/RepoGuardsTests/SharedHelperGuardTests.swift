import Foundation
import RepoGuards
import Testing

/// One implementation per helper (#2390, `dev/CONVENTIONS.md`): a second copy
/// fails here, so a fix in one never misses the other.
///
/// - A blur whose strength is a fraction of its material (a paused animator
///   whose `fractionComplete` drives a `UIBlurEffect`) is DesignSystem's
///   `ProgressBlurView`. Feed carried a copy until #2390.
/// - A count spelled short ("1.2K") is DesignSystem's `CountFormatter`,
///   which truncates. The comment rows and the subtitles rounded ("2.0k" for
///   1,999) until #2390, and Maps had its own until #2397.
struct SharedHelperGuardTests {
    /// Where the strength blur is made.
    static let progressBlur = "Packages/Core/DesignSystem/Sources/DesignSystem/Components/ProgressBlurView.swift"

    /// Where a count is spelled short.
    static let countFormatter = "Packages/Core/DesignSystem/Sources/DesignSystem/Formatting/CountFormatter.swift"

    /// Whether `text` abbreviates a count by hand: a one-decimal format
    /// followed by k, K or M.
    static func spellsACountShort(_ text: String) -> Bool {
        text.range(of: #""%\.1f[kKM]""#, options: .regularExpression) != nil
    }

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

    @Test func aShortCountIsCountFormattersAlone() throws {
        let root = RepoRoot.url
        var copies: [String] = []
        for file in try Self.sources() where file != Self.countFormatter {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            if Self.spellsACountShort(text) { copies.append(file) }
        }
        #expect(copies.isEmpty, "a count abbreviated outside CountFormatter: \(copies)")
    }

    @Test func theCountPatternSeesACopy() {
        #expect(Self.spellsACountShort(#"String(format: "%.1fk", x)"#))
        #expect(Self.spellsACountShort(#"String(format: "%.1fM", x)"#))
        #expect(!Self.spellsACountShort(#"String(format: "%.1f", x)"#))
    }

    @Test func thePatternSeesACopy() {
        #expect(Self.makesAStrengthBlur("animator.fractionComplete = x\nself.effect = UIBlurEffect(style: s)"))
        #expect(!Self.makesAStrengthBlur("self.effect = UIBlurEffect(style: s)"))
    }
}
