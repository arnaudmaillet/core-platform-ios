import Testing
import UIKit
@testable import DesignSystem

/// The stake receipt's values, the owner's of 2026-11-23 (#2529): "+N" in
/// the points' pink rising, "−N" sinking in the ground's ink, two sizes, the
/// number in place under Reduce Motion, no press on the control and one
/// shake. Reduce Motion is passed in (`moves`), never set process-wide.
@MainActor
struct StakeReceiptTests {
    /// A control in a visible window, at a known place; taken down within
    /// the test.
    private func hosting(_ body: (UIView, UIView) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        window.isHidden = false
        let host = window.rootViewController!.view!
        let anchor = UIView(frame: CGRect(x: 300, y: 500, width: 48, height: 48))
        host.addSubview(anchor)
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        try body(anchor, host)
    }

    /// The float alone, with Reduce Motion passed in: regular over media,
    /// compact on a page.
    private func float(
        _ rising: Bool, _ style: StakeReceipt.Style, moves: Bool, _ anchor: UIView, _ host: UIView
    ) -> UILabel? {
        let ground: StakeReceipt.Ground = style == .regular ? .media : .page
        return StakeReceipt.float(5, rising: rising, from: anchor, in: host, style: style, ground: ground, moves: moves)
    }

    /// The number the public entry points drew in `host`.
    private func drawn(in host: UIView) -> UILabel? {
        host.subviews.compactMap { $0 as? UILabel }.last
    }

    @Test func aSpendIsAPinkPlusOverMedia() throws {
        try hosting { anchor, host in
            StakeReceipt(anchor: anchor, host: host, style: .regular, ground: .media).spend(5)
            let label = try #require(drawn(in: host))
            #expect(label.text == "+5")
            #expect(label.textColor == LikesSymbol.tint)
            #expect(label.font == StakeReceipt.Style.regular.font)
            #expect(label.layer.shadowOpacity == 0.5, "over media the number wears its legibility shadow")
        }
    }

    @Test func anUndoIsInTheGroundsInk() throws {
        try hosting { anchor, host in
            StakeReceipt(anchor: anchor, host: host, style: .regular, ground: .media).refund(5)
            let overMedia = try #require(drawn(in: host))
            #expect(overMedia.text == "−5")
            #expect(overMedia.textColor == UIColor.white.withAlphaComponent(0.9))
            overMedia.removeFromSuperview()

            StakeReceipt(anchor: anchor, host: host, style: .compact, ground: .page).refund(5)
            let onAPage = try #require(drawn(in: host))
            #expect(onAPage.textColor == .secondaryLabel)
            #expect(onAPage.font == StakeReceipt.Style.compact.font)
            #expect(onAPage.layer.shadowOpacity == 0, "a plain page needs no shadow")
        }
    }

    @Test func bothAreBornAboveTheControlThenRiseOrSink() throws {
        try hosting { anchor, host in
            let spend = try #require(float(true, .regular, moves: true, anchor, host))
            #expect(spend.center.x == anchor.frame.midX)
            #expect(spend.center.y == anchor.frame.minY - Spacing.md - 18 - 26)
            let undo = try #require(float(false, .compact, moves: true, anchor, host))
            #expect(undo.center.y == anchor.frame.minY - Spacing.xs + 14 + 18)
        }
    }

    @Test func reduceMotionFadesTheNumberInPlace() throws {
        try hosting { anchor, host in
            let spend = try #require(float(true, .regular, moves: false, anchor, host))
            #expect(spend.center.y == anchor.frame.minY - Spacing.md)
            let undo = try #require(float(false, .compact, moves: false, anchor, host))
            #expect(undo.center.y == anchor.frame.minY - Spacing.xs)
        }
    }

    @Test func reduceMotionStillsThePop() {
        let icon = UIView()
        StakeReceipt.pop(icon, moves: false)
        #expect(icon.transform == .identity)
        #expect(icon.layer.animationKeys() == nil)
    }

    @Test func theReceiptPutsNoPressOnTheControl() {
        hosting { anchor, host in
            StakeReceipt(anchor: anchor, host: host, style: .regular, ground: .media).spend(5)
            #expect(anchor.transform == .identity)
            #expect(anchor.layer.animationKeys() == nil)
        }
    }

    @Test func aHiddenControlDrawsNothing() {
        hosting { anchor, host in
            anchor.isHidden = true
            #expect(float(true, .regular, moves: true, anchor, host) == nil)
        }
    }

    @Test func aRefusalShakesOnce() throws {
        try hosting { anchor, host in
            StakeReceipt(anchor: anchor, host: host, style: .compact, ground: .page).refuse()
            let shake = try #require(anchor.layer.animation(forKey: StakeReceipt.shakeKey) as? CAKeyframeAnimation)
            #expect(shake.keyPath == "transform.translation.x")
            #expect(shake.values as? [CGFloat] == [0, -7, 6, -4, 3, -1, 0])
            #expect(shake.duration == 0.4)
            #expect(shake.isAdditive)
        }
    }
}
