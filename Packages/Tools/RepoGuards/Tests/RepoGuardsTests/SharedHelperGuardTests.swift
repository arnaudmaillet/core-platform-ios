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
/// - A head-shake (a keyframe on `transform.translation.x`) is DesignSystem's:
///   `StakeReceipt` for a stake control's refusal, `AppControl.fail()` for a
///   button's failed action. The feed rail, the comments bar and the list
///   card each shook their own way until #2529.
/// - Staking likes with an undo toast is PostGrid's `StakeSession` (#2532,
///   ADR 0017): only it takes a stake back (`.undoBoost(`), commits one
///   (`.commitStakes(`), raises the stake's undo toast or numbers its
///   bursts. The post detail, the Snap page and the cards each staked their
///   own way until #2532.
struct SharedHelperGuardTests {
    /// Where the strength blur is made.
    static let progressBlur = "Packages/Core/DesignSystem/Sources/DesignSystem/Components/ProgressBlurView.swift"

    /// Where a count is spelled short.
    static let countFormatter = "Packages/Core/DesignSystem/Sources/DesignSystem/Formatting/CountFormatter.swift"

    /// Where a control shakes its head.
    static let headShakes: Set<String> = [
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/StakeReceipt.swift",
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/AppControl.swift",
    ]

    /// Where a stake is taken back, committed and given its undo toast.
    static let stakeSession = "Packages/Core/PostGrid/Sources/PostGrid/Staking/StakeSession.swift"

    /// The Snap page's copy, until it moves onto the session (#2532, 2/2).
    /// May only shrink: nothing is added here.
    static let stakeCopiesPending: Set<String> = [
        "Packages/Features/Feed/Sources/Feed/Snap/SnapBoostController.swift",
        "Packages/Features/Feed/Sources/Feed/Snap/SnapBoostDrive.swift",
    ]

    /// Whether `text`, comments and string literals left out, stakes by hand:
    /// it takes a stake back or commits one through the wallet, raises a
    /// stake's undo toast, or numbers a burst's toasts.
    static func stakesByHand(_ text: String) -> Bool {
        let code = EmptyActionGuardTests.strippingLineComments(text)
            .replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
        return [".undoBoost(", ".commitStakes(", "StakeMenu.undoToast(", "StakeMenu.Burst("].contains { code.contains($0) }
    }

    /// Whether `text`, comments left out, animates a horizontal shake.
    static func shakesItsHead(_ text: String) -> Bool {
        EmptyActionGuardTests.strippingLineComments(text).contains("\"transform.translation.x\"")
    }

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

    @Test func aHeadShakeIsDesignSystems() throws {
        let root = RepoRoot.url
        var copies: [String] = []
        for file in try Self.sources() where !Self.headShakes.contains(file) {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            if Self.shakesItsHead(text) { copies.append(file) }
        }
        #expect(copies.isEmpty, "a head-shake outside StakeReceipt and AppControl: \(copies)")
    }

    @Test func stakingIsTheStakeSessionsAlone() throws {
        let root = RepoRoot.url
        var copies: [String] = []
        for file in try Self.sources() where file != Self.stakeSession && !Self.stakeCopiesPending.contains(file) {
            // CoreStorage defines the wallet's calls; it does not stake.
            guard !file.hasPrefix("Packages/Core/CoreStorage/") else { continue }
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            if Self.stakesByHand(text) { copies.append(file) }
        }
        #expect(copies.isEmpty, "staking outside StakeSession (spend through a StakeSession): \(copies)")
    }

    @Test func theStakePatternSeesACopyAndNotACommentOrAString() {
        #expect(Self.stakesByHand("_ = wallet.undoBoost(targetID: key, amount: 1)"))
        #expect(Self.stakesByHand("wallet?.commitStakes(on: id.rawValue)"))
        #expect(Self.stakesByHand("let burst = StakeMenu.Burst()"))
        #expect(Self.stakesByHand("toast = StakeMenu.undoToast(staked: 1, on: key, from: self) {}"))
        #expect(!Self.stakesByHand("// wallet.undoBoost(targetID: key, amount: 1)"))
        #expect(!Self.stakesByHand(#"let hint = "call StakeMenu.undoToast( from the session""#))
        #expect(!Self.stakesByHand("stakes.undo(on: postID)"))
    }

    @Test func theShakePatternSeesACopyAndNotAComment() {
        #expect(Self.shakesItsHead(#"let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")"#))
        #expect(!Self.shakesItsHead(#"// CAKeyframeAnimation(keyPath: "transform.translation.x")"#))
        #expect(!Self.shakesItsHead(#"let fade = CABasicAnimation(keyPath: "opacity")"#))
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
