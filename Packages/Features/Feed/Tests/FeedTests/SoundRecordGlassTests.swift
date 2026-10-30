import DesignSystem
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
        // Through the holder the way back fades (#1929), never the glass.
        #expect(glass.map { record.cover.isDescendant(of: $0.contentView) } == true, "the cover is not inside the glass")
        let side = min(AvatarImageView.bubbleDiameter, record.bounds.width - 2 * SoundRecordGlass.rim)
        #expect(record.cover.bounds.size == CGSize(width: side, height: side), "the cover is not the bubble face size")
        #expect(record.cover.center == CGPoint(x: record.bounds.midX, y: record.bounds.midY))
        #expect(!record.isUserInteractionEnabled, "the host button keeps the touches")
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
