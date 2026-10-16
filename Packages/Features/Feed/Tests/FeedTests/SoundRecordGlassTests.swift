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
        #expect(record.cover.superview === glass?.contentView, "the cover is not inside the glass")
        let side = min(AvatarImageView.bubbleDiameter, record.bounds.width - 2 * SoundRecordGlass.rim)
        #expect(record.cover.bounds.size == CGSize(width: side, height: side), "the cover is not the bubble face size")
        #expect(record.cover.center == CGPoint(x: record.bounds.midX, y: record.bounds.midY))
        #expect(!record.isUserInteractionEnabled, "the host button keeps the touches")
    }

    /// ⚠️ MUTED IS SAID IN THE MIDDLE (the owner, 2026-10-16): a large
    /// speaker-slash centred on the record, half its side, with no plate —
    /// the only glass is the record's own.
    @Test func theMutedGlyphIsCentredLargeAndBare() {
        let record = SoundRecordGlass()
        record.coverSide = nil
        let window = hosted(record, side: 96)
        defer { window.isHidden = true }
        record.showsMutedBadge = true
        record.layoutIfNeeded()
        let glyph = record.debugMutedGlyph
        #expect(glyph.frame.midX == record.cover.frame.midX && glyph.frame.midY == record.cover.frame.midY)
        #expect(glyph.pointSize == SoundRecordGlass.mutedGlyphPointSize(forRecordSide: record.cover.bounds.width))
        #expect(glyph.pointSize >= record.cover.bounds.width * 0.45, "the muted glyph is not large")
        #expect(effectViews(in: record).count == 1, "the muted glyph sits on a plate of its own")
    }

    /// On a window the muted glyph bounces in and out (the owner,
    /// 2026-10-16), and the cover darkens behind it while it shows.
    @Test func theMutedGlyphComesAndGoesAnimatedOverADimmedCover() {
        let record = SoundRecordGlass()
        let window = hosted(record, side: 96)
        defer { window.isHidden = true }
        #expect(!record.debugCoverDimmed)
        record.showsMutedBadge = true
        #expect(record.showsMutedBadge)
        #expect(record.debugCoverDimmed, "the cover did not darken behind 🔇")
        #expect(record.debugMutedGlyphAnimating, "the glyph appeared without its bounce")
        record.showsMutedBadge = false
        #expect(!record.showsMutedBadge)
        #expect(!record.debugCoverDimmed)
        #expect(record.debugMutedGlyphAnimating, "the glyph left without its bounce out")
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
