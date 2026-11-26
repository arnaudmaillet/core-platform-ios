import DesignSystem
import Testing
import UIKit
@testable import ThreadKit

/// Share in a bubble (#2581): the page's bubble and the composer's slot draw
/// the plane at `ShareBubbleGlyph`'s size, the like pill's heart's by its
/// drawn ink, and stand its image `ShareBubbleGlyph.offset()` off the
/// bubble's centre, which puts its ink's centre of mass there.
/// `AppSymbolSizeTests` measures the ink itself; these read what each site
/// draws and where.
@MainActor
struct ShareBubbleGlyphTests {
    private func hosted(_ view: UIView, side: CGFloat) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.frame = CGRect(x: 20, y: 20, width: side, height: side)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        return window
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    /// The image view a configured button draws its image in, laid out.
    private func drawnImage(of button: UIButton) throws -> UIImageView {
        button.setNeedsLayout()
        button.layoutIfNeeded()
        let views = descendants(button).compactMap { $0 as? UIImageView }.filter { $0.image != nil && !$0.isHidden }
        return try #require(views.first, "the button draws no image")
    }

    /// The like pill's heart, the size Share matches: 15 pt semibold, drawn by
    /// its configured button at the `.large` scale (20.7 × 17.7 pt of ink).
    @Test func theLikePillDrawsItsHeartAtTheLargeScale() throws {
        let config = SnapActionColumn.likeConfiguration(.plain(), staked: false, count: nil, ink: .label)
        let button = UIButton(configuration: config)
        let window = hosted(button, side: SnapActionColumn.bubbleSize)
        defer { window.isHidden = true }
        let drawn = try drawnImage(of: button)
        let large = try #require(UIImage.symbol(named: LikesSymbol.outlineGlyph, configuration: AppSymbolSizeReference.drawnHeart))
        #expect(abs(drawn.bounds.width - large.size.width) < 0.01 && abs(drawn.bounds.height - large.size.height) < 0.01,
                "the heart is drawn \(drawn.bounds.size), not the large scale's \(large.size)")
    }

    /// The page's Share bubble (both layouts' `SnapSoundBubbleButton`): the
    /// plane at the bubble size, moved down and left by the offset.
    @Test func theBubblesShareIsDrawnAtTheBubbleSizeAndCentredByItsInk() throws {
        let bubble = SnapSoundBubbleButton()
        bubble.isHidden = false
        let window = hosted(bubble, side: SnapActionColumn.bubbleSize)
        defer { window.isHidden = true }
        bubble.setSharesPost(true)
        bubble.layoutIfNeeded()
        let image = try #require(bubble.debugGlyph.image)
        let expected = try #require(ShareBubbleGlyph.image())
        #expect(image.size == expected.size, "Share is \(image.size), the bubble size draws \(expected.size)")
        let old = try #require(UIImage.symbol(named: PostActionSymbol.share, configuration: AppSymbol.fixed(17, weight: .semibold)))
        #expect(image.size.width > old.size.width, "Share is still drawn at the composer's 17 pt")
        let move = ShareBubbleGlyph.offset()
        let centre = CGPoint(x: bubble.bounds.midX + move.horizontal, y: bubble.bounds.midY + move.vertical)
        #expect(hypot(bubble.debugGlyph.center.x - centre.x, bubble.debugGlyph.center.y - centre.y) < 0.01,
                "the glyph stands at \(bubble.debugGlyph.center), not \(centre)")
        #expect(move.horizontal < -1 && move.vertical > 1, "the plane is not moved down and left: \(move)")
    }

    /// The way back's chevrons keep the slot's 15 pt and the bubble's centre.
    @Test func theBubblesWayBackKeepsItsSizeAndCentre() throws {
        let bubble = SnapSoundBubbleButton()
        bubble.isHidden = false
        let window = hosted(bubble, side: SnapActionColumn.bubbleSize)
        defer { window.isHidden = true }
        bubble.setSharesPost(true)
        bubble.setShowsReturn(true, animated: false)
        bubble.layoutIfNeeded()
        let image = try #require(bubble.debugGlyph.image)
        let chevron = try #require(UIImage(systemName: "chevron.up", withConfiguration: AppSymbol.fixed(15, weight: .semibold)))
        #expect(image.size == chevron.size)
        let centre = CGPoint(x: bubble.bounds.midX, y: bubble.bounds.midY)
        #expect(hypot(bubble.debugGlyph.center.x - centre.x, bubble.debugGlyph.center.y - centre.y) < 0.01)
    }

    /// The composer's slot: Share at the bubble size, through the glass's
    /// insets moved as `ShareBubbleGlyph` moves them (`AppSymbolSizeTests`
    /// lays a configured button out and finds the image where it should be);
    /// another face goes back to the glass's own insets and the column's 15 pt.
    @Test func theSlotsShareIsDrawnAtTheBubbleSizeAndCentredByItsInk() throws {
        let bar = CommentsInputBar()
        bar.railFace = .share
        let button = bar.debugRailButton
        let expected = try #require(ShareBubbleGlyph.image())
        let image = try #require(button.configuration?.image)
        #expect(image.size == expected.size, "the slot draws Share \(image.size), the bubble size is \(expected.size)")
        let resting = UIButton.Configuration.glass().contentInsets
        let moved = ShareBubbleGlyph.contentInsets(resting, for: expected, direction: .leftToRight)
        #expect(button.configuration?.contentInsets == moved, "\(String(describing: button.configuration?.contentInsets)) vs \(moved)")
        #expect(moved.top > resting.top && moved.trailing > resting.trailing, "Share is not moved down and left: \(moved)")

        bar.railFace = .pin(isPinned: false)
        #expect(button.configuration?.contentInsets == resting)
        let pin = try #require(UIImage.symbol(named: AppSymbol.bookmark.rawValue, configuration: AppSymbol.fixed(15, weight: .semibold)))
        #expect(button.configuration?.image?.size == pin.size)
    }
}

/// The like pill's heart as its button draws it: 15 pt semibold at `.large`,
/// the reference `AppSymbolSizeTests` measures Share against.
enum AppSymbolSizeReference {
    static let drawnHeart = SnapActionColumn.heartConfiguration.applying(UIImage.SymbolConfiguration(scale: .large))
}
