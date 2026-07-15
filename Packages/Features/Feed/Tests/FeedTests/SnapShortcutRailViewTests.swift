import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The shortcut wheel's geometry contract: a full-height rail whose resting
/// window shows exactly three bubbles docked at the bottom, with the rest
/// scroll-discoverable, detent-snapped releases, and a per-post deterministic
/// placeholder payload (the flight-replica identity requirement).
@MainActor
struct SnapShortcutRailViewTests {
    /// A rail frame comfortably taller than the resting window, as on device
    /// (ticker top → nav bar bottom).
    private static let railHeight: CGFloat = 520

    private func makeRail(symbolCount: Int = 9) -> SnapShortcutRailView {
        let rail = SnapShortcutRailView(
            frame: CGRect(x: 0, y: 0, width: 44, height: Self.railHeight)
        )
        rail.setSymbols(Array(SnapShortcutRailView.symbolPool.prefix(symbolCount)))
        rail.layoutIfNeeded()
        return rail
    }

    @Test func restingWindowShowsExactlyThreeIcons() {
        let rail = makeRail()
        // The top inset pads the scroll range down to the resting window,
        // docked one fade band clear of the rail's soft bottom edge…
        #expect(rail.contentInset.top
            == Self.railHeight - SnapShortcutRailView.restingWindowHeight - SnapShortcutRailView.edgeFadeLength)
        // …and the rail rests parked against it.
        #expect(rail.contentOffset.y == -rail.contentInset.top)
        #expect(rail.visibleIconCount == SnapShortcutRailView.restingIconCount)
    }

    @Test func scrollingUpRevealsTheFullColumn() {
        let rail = makeRail()
        let maxOffset = rail.contentSize.height - rail.bounds.height + rail.contentInset.bottom
        // Nine bubbles fit inside the 520pt rail, so the top clamp reveals
        // them all, bottom-aligned above the fade band.
        rail.contentOffset = CGPoint(x: 0, y: maxOffset)
        #expect(rail.visibleIconCount == 9)
    }

    @Test func sizeChurnPreservesRevealProgress() {
        let rail = makeRail()
        // The user has revealed two detents…
        let revealed = -rail.contentInset.top + 2 * SnapShortcutRailView.step
        rail.contentOffset = CGPoint(x: 0, y: revealed)
        // …then the rail's height ticks (safe-area churn, rotation). The
        // rebuild must carry the reveal progress, not stomp back to rest —
        // the stomp is the "icons abruptly vanish mid-scroll" bug.
        rail.frame.size.height = Self.railHeight - 40
        rail.layoutIfNeeded()
        #expect(rail.contentOffset.y == -rail.contentInset.top + 2 * SnapShortcutRailView.step)
        // A fresh payload, by contrast, parks back at rest.
        rail.setSymbols(Array(SnapShortcutRailView.symbolPool.prefix(9)))
        rail.layoutIfNeeded()
        #expect(rail.contentOffset.y == -rail.contentInset.top)
    }

    @Test func hiddenIconsAreScrollDiscoverable() {
        let rail = makeRail()
        // contentSize covers the whole column, clipped bubbles included…
        let step = SnapShortcutRailView.step
        #expect(rail.contentSize.height == 9 * SnapShortcutRailView.iconDiameter + 8 * SnapShortcutRailView.iconSpacing)
        // …and the scrollable range (rest → top clamp) is exactly the six
        // hidden bubbles' worth of travel. A zero or negative range here is
        // the "wheel is frozen" regression.
        let maxOffset = rail.contentSize.height - rail.bounds.height + rail.contentInset.bottom
        let travel = maxOffset - (-rail.contentInset.top)
        #expect(travel == 6 * step)
        // The wheel always rubber-bands, even below the scrollability line.
        #expect(rail.alwaysBounceVertical)
    }

    @Test func placeholderPayloadOutnumbersTheRestingWindow() {
        // The wheel ships more shortcuts than the resting window shows —
        // otherwise there is nothing to discover and the rail reads dead.
        #expect(SnapShortcutRailView.symbolPool.count >= 8)
        #expect(SnapShortcutRailView.symbolPool.count > SnapShortcutRailView.restingIconCount)
    }

    @Test func emptyPayloadHidesTheRail() {
        let rail = makeRail()
        #expect(rail.isHidden == false)
        rail.reset()
        #expect(rail.isHidden == true)
        #expect(rail.visibleIconCount == 0)
    }

    @Test func releasesSnapToTheStepGrid() {
        let step = SnapShortcutRailView.step
        let rest: CGFloat = -388 // arbitrary rest offset
        let max: CGFloat = -100

        // In-range proposals round to the nearest detent…
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: rest + 1.4 * step, restOffset: rest, step: step, maxOffset: max
        ) == rest + step)
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: rest + 1.6 * step, restOffset: rest, step: step, maxOffset: max
        ) == rest + 2 * step)
        // …and rounding can never escape the scrollable range.
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: rest - step, restOffset: rest, step: step, maxOffset: max
        ) == rest)
        #expect(SnapShortcutRailView.snappedTarget(
            proposed: 0, restOffset: rest, step: step, maxOffset: max
        ) == max)
    }

    @Test func edgeFlicksAreLeftToTheNativeSpring() {
        let rail = makeRail()
        #expect(rail.bounces)
        #expect(rail.alwaysBounceVertical)
        #expect(rail.decelerationRate == .fast)

        let restOffset = -rail.contentInset.top
        let maxOffset = rail.contentSize.height - rail.bounds.height + rail.contentInset.bottom

        // A proposal past either boundary is an edge flick: the delegate
        // must not touch it — handing UIKit a boundary-clamped target kills
        // the overshoot spring and the edge reads as a hard wall.
        var pastTop = CGPoint(x: 0, y: maxOffset + 120)
        rail.scrollViewWillEndDragging(rail, withVelocity: CGPoint(x: 0, y: 2), targetContentOffset: &pastTop)
        #expect(pastTop.y == maxOffset + 120)
        var pastRest = CGPoint(x: 0, y: restOffset - 80)
        rail.scrollViewWillEndDragging(rail, withVelocity: CGPoint(x: 0, y: -2), targetContentOffset: &pastRest)
        #expect(pastRest.y == restOffset - 80)

        // In-range releases still settle on the detent grid.
        var inRange = CGPoint(x: 0, y: restOffset + 1.4 * SnapShortcutRailView.step)
        rail.scrollViewWillEndDragging(rail, withVelocity: .zero, targetContentOffset: &inRange)
        #expect(inRange.y == restOffset + SnapShortcutRailView.step)
    }

    @Test func railGestureSuspendsAncestorScrollingUntilSettle() {
        let rail = makeRail()
        let pager = UIScrollView()
        pager.addSubview(rail)

        // Gesture arbitration can't stop UIKit's overscroll chaining (it
        // writes the ancestor's offset directly, no recognizer involved) —
        // the pager is suspended for the gesture's whole span instead.
        rail.scrollViewWillBeginDragging(rail)
        #expect(pager.isScrollEnabled == false)
        // Release into deceleration: still the rail's gesture — stay locked.
        rail.scrollViewDidEndDragging(rail, willDecelerate: true)
        #expect(pager.isScrollEnabled == false)
        rail.scrollViewDidEndDecelerating(rail)
        #expect(pager.isScrollEnabled == true)

        // A dead-stop release thaws immediately.
        rail.scrollViewWillBeginDragging(rail)
        rail.scrollViewDidEndDragging(rail, willDecelerate: false)
        #expect(pager.isScrollEnabled == true)

        // Teardown mid-gesture (cell recycle) can never strand the feed.
        rail.scrollViewWillBeginDragging(rail)
        #expect(pager.isScrollEnabled == false)
        rail.reset()
        #expect(pager.isScrollEnabled == true)
    }

    @Test func swipesWinOverBubblePressStates() {
        let rail = makeRail()
        // Un-delayed content touches (`delaysContentTouches = false`) need
        // both cancellation halves, or a finger landing on a bubble locks
        // the wheel for the whole press: the rail may cancel content
        // touches, and specifically may cancel a UIControl's.
        #expect(rail.canCancelContentTouches)
        #expect(rail.touchesShouldCancel(in: UIButton()) == true)
    }

    @Test func pagerDeclinesTouchesBornInTheRail() {
        // The geometric divorce: anything hit-tested inside the rail (a
        // bubble, a gap between bubbles, the rail itself) belongs to the
        // rail — the feed's recognizers must decline it. Anything else
        // (media, caption, chrome) is the pager's.
        let rail = makeRail()
        let bubble = UIButton()
        rail.addSubview(bubble)
        #expect(SnapFeedCollectionView.belongsToShortcutRail(rail) == true)
        #expect(SnapFeedCollectionView.belongsToShortcutRail(bubble) == true)
        // The fixed compose "+" is rail territory too (chrome sibling, so
        // the walk-up can't find the rail — its class is the marker).
        #expect(SnapFeedCollectionView.belongsToShortcutRail(SnapRailComposeButton()) == true)
        let caption = UILabel()
        #expect(SnapFeedCollectionView.belongsToShortcutRail(caption) == false)
    }

    @Test func placeholderPayloadIsDeterministicPerPost() {
        let id = PostID("0198c5f2-1111-7000-8000-000000000001")
        // Same post → same wheel (the live cell and its flight replica must
        // never disagree).
        #expect(SnapShortcutRailView.placeholderPayload(for: id)
            == SnapShortcutRailView.placeholderPayload(for: id))
        // Full pool, no duplicates — it's a shuffle, not a sample.
        let payload = SnapShortcutRailView.placeholderPayload(for: id)
        #expect(Set(payload).count == SnapShortcutRailView.symbolPool.count)
    }

    /// The chrome-level contract this feature is really about: the rail owns
    /// the trailing column (ticker top → nav bar) and the subtitle zone's
    /// slot stops short of it instead of running the full width.
    @Test func chromeReservesTheTrailingColumnForTheRail() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.layoutIfNeeded()

        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)

        // Trailing column: as wide as the ticker band is TALL (the square
        // contract), Spacing.md off the margin (no window → zero safe area
        // → margins guide == bounds).
        #expect(rail.frame.width == ticker.frame.height)
        #expect(rail.frame.maxX == 390 - Spacing.md)
        // Vertical span: under the nav bar down THROUGH the ticker band —
        // the wheel's bubbles overlap the band on the glass pedestal.
        #expect(rail.frame.minY == Spacing.sm)
        #expect(rail.frame.maxY == ticker.frame.maxY)
        // The subtitle zone stops short of the rail — the width reduction.
        #expect(subtitle.frame.maxX == rail.frame.minX - Spacing.md)
        // A media post shows its wheel.
        #expect(rail.isHidden == false)

        // The glass pedestal covers exactly the rail↔ticker overlap — a
        // PERFECT SQUARE (width == the band's height) — and sits BETWEEN
        // them: above the band's text, below the bubbles.
        let glass = try #require(chrome.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        #expect(glass.frame.minY == ticker.frame.minY)
        #expect(glass.frame.maxY == ticker.frame.maxY)
        #expect(glass.frame.maxX == rail.frame.maxX)
        #expect(glass.frame.width == glass.frame.height)
        let order = chrome.subviews
        #expect(order.firstIndex(of: ticker)! < order.firstIndex(of: glass)!)
        #expect(order.firstIndex(of: glass)! < order.firstIndex(of: rail)!)

        // The band's trailing edge sits exactly on the square's outer
        // threshold (and the band clips): bubbles are born under the
        // frosted square and slide out of its seam — the storytelling
        // alignment. Leading stays full-bleed.
        #expect(ticker.frame.maxX == glass.frame.maxX)
        #expect(ticker.frame.minX == 0)
        #expect(ticker.clipsToBounds)

        // The fixed "+" centers in the square, ABOVE the rail (a chrome
        // sibling — it never scrolls), and the rail reserves its bottom
        // strip so no emote settles behind it.
        let compose = try #require(chrome.subviews.compactMap { $0 as? SnapRailComposeButton }.first)
        // Pixel-snapped centering (frames align to the 3x grid).
        #expect(abs(compose.center.x - glass.frame.midX) < 0.5)
        #expect(abs(compose.center.y - glass.frame.midY) < 0.5)
        #expect(order.firstIndex(of: rail)! < order.firstIndex(of: compose)!)
        #expect(rail.bottomReservedInset == ticker.frame.height)
    }

    @Test func edgeMaskCoversTheVisibleWindowFromTheFirstLayout() throws {
        let rail = makeRail()
        rail.bottomReservedInset = 45
        rail.layoutIfNeeded()
        // The fade mask must frame the VISIBLE window — bounds at the rest
        // offset — on the FIRST layout, not content-zero. A stale origin
        // maps the reserved "+" strip onto the wrong content slice, and
        // the overflow bubble renders opaque on the button until the first
        // scroll re-lays the mask ("icons above the + on first frame").
        let mask = try #require(rail.layer.mask as? CAGradientLayer)
        #expect(mask.frame.origin.y == rail.contentOffset.y)
        #expect(mask.frame.height == rail.bounds.height)
        // And the strip is fully masked out at the bottom: the last color
        // stop (clear) sits one reserved-strip above the bottom edge.
        let lastStop = try #require(mask.locations?.last).doubleValue
        #expect(abs(lastStop - (1 - 45 / Self.railHeight)) < 0.001)
    }

    @Test func reservedBottomStripKeepsSettlesClearOfTheComposeSquare() {
        let rail = makeRail()
        rail.bottomReservedInset = 45
        rail.layoutIfNeeded()
        // The resting window rises by the reserved strip…
        #expect(rail.contentInset.top
            == Self.railHeight - SnapShortcutRailView.restingWindowHeight - SnapShortcutRailView.edgeFadeLength - 45)
        #expect(rail.contentOffset.y == -rail.contentInset.top)
        #expect(rail.visibleIconCount == SnapShortcutRailView.restingIconCount)
        // …and the top clamp's bottom alignment clears it too.
        let maxOffset = rail.contentSize.height - rail.bounds.height + rail.contentInset.bottom
        #expect(rail.contentInset.bottom == 45 + SnapShortcutRailView.edgeFadeLength)
        // Travel stays exactly the hidden bubbles' worth — the strip
        // shifts both endpoints, never the range.
        #expect(maxOffset - (-rail.contentInset.top) == 6 * SnapShortcutRailView.step)
    }

    @Test func glassPedestalMirrorsTheTickerBand() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-3"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/3"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        let glass = try #require(chrome.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        // No band content → no glass floating over bare media.
        #expect(glass.isHidden == true)
        // The band arriving brings its pedestal with it…
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<8).map { TickerCommentModel(id: "c\($0)", text: "fire \($0)") },
            subtitles: [],
            commentCount: 8
        ))
        #expect(glass.isHidden == UIAccessibility.isReduceMotionEnabled)
        // …and an emptied stream takes it back down.
        chrome.updateCommentStreams(.empty)
        #expect(glass.isHidden == true)
    }

    @Test func railTopTracksSettledMarginsButFreezesThroughFlightChurn() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)

        // A settled top margin (status bar + nav bar) flows into the rail's
        // cell-relative top…
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        #expect(rail.frame.minY == 103 + Spacing.sm)

        // …but mid-flight safe-area churn (insets far past any real nav
        // clearance, re-propagated while the cell rides a transition) is
        // rejected: the rail's frame holds still so icons ride the page
        // instead of drifting toward the screen's safe boundary.
        chrome.setFixedInsets(UIEdgeInsets(top: 420, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        #expect(rail.frame.minY == 103 + Spacing.sm)
    }

    @Test func cellFreezesChromeToPushedBarThresholds() throws {
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // The feed VC pushes the SCREEN's header/footer thresholds (its own
        // safe-area insets); the cell freezes its chrome to them, ending
        // ambient safe-area tracking — a moving cell's ambient insets
        // re-derive every transition frame and must not bound the zone.
        cell.applyChromeInsets(UIEdgeInsets(top: 116, left: 0, bottom: 83, right: 0))
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        #expect(chrome.layoutMargins.top == 116)
        #expect(chrome.layoutMargins.bottom == 83)
        #expect(chrome.insetsLayoutMarginsFromSafeArea == false)
    }

    @Test func textOnlyPostsKeepTheEmptyShell() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-2"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "text-only thought",
            mediaURL: nil,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        #expect(rail.isHidden == true)
    }
}
