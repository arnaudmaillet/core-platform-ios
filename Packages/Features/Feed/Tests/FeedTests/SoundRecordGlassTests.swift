import Testing
import UIKit
@testable import Feed

/// The sound's record IN its glass (#1150): the cover is the glass's
/// content, the muted badge sits inside the rim, and a press moves both.
@MainActor
struct SoundRecordGlassTests {
    private func hosted(_ view: UIView, side: CGFloat = 48) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.frame = CGRect(x: 20, y: 20, width: side, height: side)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    private func effectViews(in view: UIView) -> [UIVisualEffectView] {
        view.subviews.flatMap { ($0 as? UIVisualEffectView).map { [$0] + effectViews(in: $0.contentView) } ?? effectViews(in: $0) }
    }

    @Test func theCoverIsTheGlasssContent() {
        let record = SoundRecordGlass()
        let window = hosted(record)
        defer { window.isHidden = true }
        let glass = try? #require(effectViews(in: record).first)
        #expect(glass?.effect is UIGlassEffect, "the glass did not materialize on the window")
        #expect(record.cover.superview === glass?.contentView, "the cover is not inside the glass")
        #expect(record.cover.frame == record.bounds.insetBy(dx: SoundRecordGlass.rim, dy: SoundRecordGlass.rim))
        #expect(!record.isUserInteractionEnabled, "the host button keeps the touches")
    }

    /// Inside the rim, never across it: every corner of the badge's square
    /// lies within the circle less the rim.
    @Test(arguments: [36, 44, 48, 56] as [CGFloat])
    func theBadgeSitsInsideTheRim(side: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let badge = SoundRecordGlass.badgeFrame(in: bounds)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // The badge is a disc: its farthest point from the centre.
        let farthest = hypot(badge.midX - center.x, badge.midY - center.y) + badge.width / 2
        #expect(farthest <= side / 2 - SoundRecordGlass.rim + 0.001)
        #expect(badge.midX > center.x && badge.midY > center.y, "bottom-trailing")
    }

    @Test func theBadgeIsGlassToo() {
        let record = SoundRecordGlass()
        let window = hosted(record)
        defer { window.isHidden = true }
        record.showsMutedBadge = true
        let glasses = effectViews(in: record)
        #expect(glasses.count == 2)
        #expect(glasses.allSatisfy { $0.effect is UIGlassEffect })
    }

    @Test func thePressMovesTheGlassAndTheRecordTogether() {
        let bubble = SnapSoundBubbleButton()
        let window = hosted(bubble)
        defer { window.isHidden = true }
        bubble.isHighlighted = true
        #expect(bubble.debugRecord.transform.a > 1, "the press did not grow the record")
        bubble.isHighlighted = false
        #expect(bubble.debugRecord.transform == .identity)
        #expect(bubble.configuration?.background.backgroundColor == .clear, "the button drew a glass of its own")
    }
}
