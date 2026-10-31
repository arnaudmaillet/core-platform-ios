import Testing
import UIKit
@testable import Feed

/// A danmaku bubble wears a capsule (#1987): since the page's scrim stops
/// at the caption block (#1983), it is the band's only contrast. The capsule
/// is the layer's own fill and corner, never a shadow, a mask or a blur — an
/// offscreen pass per frame per bubble over a playing video.
@MainActor
struct TickerBubbleCapsuleTests {
    private func bubble(height: CGFloat = 22, text: String = "fire") -> TickerBubbleView {
        let bubble = TickerBubbleView()
        bubble.configure(text: text, avatarURL: nil, monogram: "AN", pipeline: nil)
        bubble.frame = CGRect(x: 0, y: 0, width: TickerBubbleView.width(forTextWidth: 40, height: height), height: height)
        bubble.layoutIfNeeded()
        return bubble
    }

    @Test func aBubbleIsAFilledCapsule() throws {
        let bubble = bubble()
        let fill = try #require(bubble.layer.backgroundColor)
        #expect(fill.alpha > 0)
        #expect(bubble.layer.cornerRadius == bubble.bounds.height / 2)
    }

    @Test func itCostsNoOffscreenPass() {
        let bubble = bubble()
        #expect(!bubble.layer.masksToBounds)
        #expect(!bubble.clipsToBounds)
        #expect(bubble.layer.shadowOpacity == 0)
        #expect(bubble.layer.mask == nil)
        #expect(!bubble.subviews.contains { $0 is UIVisualEffectView })
    }

    /// The avatar's circle nests concentric in the capsule's rounded end, and
    /// the text stops short of the other end.
    @Test func theAvatarNestsInTheCapsulesEnd() {
        let bubble = bubble(height: 24)
        #expect(bubble.avatarView.frame.minX == (24 - TickerBubbleView.avatarDiameter) / 2)
        #expect(bubble.avatarView.frame.midY == 12)
    }

    /// The band measures a bubble with its capsule's ends, so the text keeps
    /// its room.
    @Test func theWidthCountsTheCapsulesEnds() {
        let height: CGFloat = 22
        let width = TickerBubbleView.width(forTextWidth: 40, height: height)
        #expect(width == TickerBubbleView.capsuleLeadingInset(height: height) + TickerBubbleView.avatarDiameter
            + TickerBubbleView.avatarGap + 40 + TickerBubbleView.capsuleTrailingPadding)
    }

    /// A pooled bubble keeps its capsule.
    @Test func aRecycledBubbleKeepsItsCapsule() throws {
        let bubble = bubble()
        bubble.prepareForReuse()
        bubble.configure(text: "again", avatarURL: nil, monogram: "AN", pipeline: nil)
        #expect(try #require(bubble.layer.backgroundColor).alpha > 0)
    }
}
