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
        // The geometric divorce: anything hit-tested inside touch-owning
        // territory (a rail bubble, a gap between bubbles, the rail itself,
        // the engaged comments container's rows) claims the touch — the
        // feed's recognizers must decline it. Anything else (media,
        // caption, chrome) is the pager's.
        let rail = makeRail()
        let bubble = UIButton()
        rail.addSubview(bubble)
        #expect(SnapFeedCollectionView.claimsTouches(rail) == true)
        #expect(SnapFeedCollectionView.claimsTouches(bubble) == true)
        // The fixed compose "+" is rail territory too (chrome sibling, so
        // the walk-up can't find the rail — its class is the marker).
        #expect(SnapFeedCollectionView.claimsTouches(SnapRailComposeButton()) == true)
        // The comments container is the engagement's scroll territory: the
        // list's drags stay inner (edge bounces rubber-band, never page) —
        // EXCEPT the composer band, which forwards its drags to the pager
        // (the swipe exit) even though it descends from the container.
        let comments = SnapCommentsContainerView()
        let innerRow = UIView()
        comments.addSubview(innerRow)
        let inputBar = CommentsInputBar()
        comments.addSubview(inputBar)
        let insideInput = UIView()
        inputBar.addSubview(insideInput)
        #expect(SnapFeedCollectionView.claimsTouches(comments) == true)
        #expect(SnapFeedCollectionView.claimsTouches(innerRow) == true)
        #expect(SnapFeedCollectionView.claimsTouches(inputBar) == false)
        #expect(SnapFeedCollectionView.claimsTouches(insideInput) == false)
        let caption = UILabel()
        #expect(SnapFeedCollectionView.claimsTouches(caption) == false)
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
        // the wheel's bubbles overlap the band on the glass pedestal. The
        // top sits at base clearance PLUS the sub-step excess the chrome
        // absorbs to grid-align the headroom (always less than one step).
        #expect(rail.frame.minY >= Spacing.sm)
        #expect(rail.frame.minY - Spacing.sm < SnapShortcutRailView.step)
        #expect(abs(rail.frame.maxY - ticker.frame.maxY) < 0.01)
        // The subtitle zone stops short of the rail — the width reduction.
        #expect(subtitle.frame.maxX == rail.frame.minX - Spacing.md)
        // A media post shows its wheel.
        #expect(rail.isHidden == false)

        // The fixed "+" anchor is the overlap zone's ONLY layer (the old
        // frosted chip is gone): a Liquid Glass circle whose box fills
        // 100% of the square — width == height == the band's height —
        // sitting ABOVE the rail (a chrome sibling; it never scrolls).
        let compose = try #require(chrome.subviews.compactMap { $0 as? SnapRailComposeButton }.first)
        #expect(chrome.subviews.compactMap { $0 as? UIVisualEffectView }.isEmpty)
        #expect(compose.frame.minY == ticker.frame.minY)
        #expect(abs(compose.frame.maxY - ticker.frame.maxY) < 0.01)
        #expect(abs(compose.frame.maxX - rail.frame.maxX) < 0.01)
        #expect(abs(compose.frame.width - compose.frame.height) < 0.01)
        #expect(compose.configuration?.cornerStyle == .capsule)
        let order = chrome.subviews
        #expect(order.firstIndex(of: ticker)! < order.firstIndex(of: rail)!)
        #expect(order.firstIndex(of: rail)! < order.firstIndex(of: compose)!)
        #expect(rail.bottomReservedInset == ticker.frame.height)

        // The band's trailing edge sits at the anchor's outer threshold
        // (and the band clips): bubbles are born under the glass circle
        // and slide out of its seam — the storytelling alignment. Leading
        // stays full-bleed, and the clip's RIGHT end is a CAPSULE (radius
        // = half the band's height) nesting inside the circle's curvature,
        // so no clipped bubble sliver peeks out of the corner gaps.
        // (Sub-point tuck inside the anchor — pixel-snapped from 0.5pt —
        // so independent rounding can't leave a clip-line sliver proud of
        // the zone's edge. Strictly inside, less than a point.)
        let tuck = compose.frame.maxX - ticker.frame.maxX
        #expect(tuck > 0)
        #expect(tuck < 1)
        #expect(ticker.frame.minX == 0)
        #expect(ticker.clipsToBounds)
        #expect(ticker.layer.cornerRadius == ticker.frame.height / 2)
        #expect(ticker.layer.maskedCorners == [.layerMaxXMinYCorner, .layerMaxXMaxYCorner])

        // Grid-aligned headroom: the chrome absorbs sub-step excess into
        // the rail's top constant so `contentInset.top` is a whole number
        // of detents — the invariant that makes settled top-exits pure
        // (tolerance: frames pixel-align to the 3x grid).
        let remainder = rail.contentInset.top.truncatingRemainder(dividingBy: SnapShortcutRailView.step)
        #expect(remainder < 0.34 || remainder > SnapShortcutRailView.step - 0.34)
    }

    @Test func topExitInterpolationIsPureOnTheDetentGrid() {
        // A rail whose headroom IS grid-aligned (the chrome's invariant):
        // 132 resting + 16 fade + 288 headroom (= 6 detents) = 436.
        let rail = SnapShortcutRailView(frame: CGRect(x: 0, y: 0, width: 44, height: 436))
        rail.setSymbols(Array(SnapShortcutRailView.symbolPool.prefix(9)))
        rail.layoutIfNeeded()
        let icons = rail.subviews.compactMap { $0 as? UIButton }.sorted { $0.center.y < $1.center.y }

        // At rest: every emote is full-size and fully opaque.
        #expect(icons.allSatisfy { $0.alpha == 1 })
        #expect(icons.allSatisfy { $0.transform == .identity })

        // Fully revealed (the top clamp, a settled detent): the exiting
        // emote is COMPLETELY collapsed, its successor perfectly at rest —
        // no half state can survive a settle.
        rail.contentOffset = CGPoint(x: 0, y: rail.contentSize.height - rail.bounds.height + rail.contentInset.bottom)
        rail.layoutIfNeeded()
        #expect(icons[0].alpha == 0)
        #expect(icons[1].alpha == 1)
        #expect(icons[1].transform == .identity)

        // Mid-drag between detents: smooth interpolation (half a step in
        // the exit zone = half faded, scale halfway to the floor).
        rail.contentOffset.y -= SnapShortcutRailView.step / 2
        rail.layoutIfNeeded()
        #expect(abs(icons[0].alpha - 0.5) < 0.01)
        let expectedScale = SnapShortcutRailView.exitScaleFloor + (1 - SnapShortcutRailView.exitScaleFloor) * 0.5
        #expect(abs(icons[0].transform.a - expectedScale) < 0.01)
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

    @Test func bandHeightIsAuthoritativeOverTheAnchor() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-4"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/4"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.layoutIfNeeded()
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)
        let compose = try #require(chrome.subviews.compactMap { $0 as? SnapRailComposeButton }.first)

        // One-directional height authority: the band resolves to exactly
        // its intrinsic (type-metric) height — the anchor pinned to its
        // edges can neither squeeze nor stretch it — and the system is
        // UNAMBIGUOUS (two competing 750-priority intrinsic sizes joined
        // by equality constraints once resolved either way per pass: the
        // height jitter).
        #expect(ticker.frame.height == ticker.intrinsicContentSize.height)
        #expect(ticker.hasAmbiguousLayout == false)
        #expect(compose.hasAmbiguousLayout == false)
        #expect(ticker.contentHuggingPriority(for: .vertical) == .required)
        #expect(ticker.contentCompressionResistancePriority(for: .vertical) == .required)
        #expect(compose.contentHuggingPriority(for: .vertical) == UILayoutPriority(1))
        #expect(compose.contentCompressionResistancePriority(for: .vertical) == UILayoutPriority(1))
    }

    @Test func composeAnchorMirrorsTheTickerBand() throws {
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
        let compose = try #require(chrome.subviews.compactMap { $0 as? SnapRailComposeButton }.first)
        // No band content → no "+" anchor floating over bare media.
        #expect(compose.isHidden == true)
        // The band arriving brings its anchor with it…
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<8).map { TickerCommentModel(id: "c\($0)", text: "fire \($0)") },
            subtitles: [],
            commentCount: 8
        ))
        #expect(compose.isHidden == UIAccessibility.isReduceMotionEnabled)
        // …and an emptied stream takes it back down.
        chrome.updateCommentStreams(.empty)
        #expect(compose.isHidden == true)
    }

    @Test func railTopTracksSettledMarginsButFreezesThroughFlightChurn() throws {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)

        // A settled top margin (status bar + nav bar) flows into the rail's
        // cell-relative top (plus the sub-step grid-alignment excess)…
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        let settledMinY = rail.frame.minY
        #expect(settledMinY >= 103 + Spacing.sm)
        #expect(settledMinY - (103 + Spacing.sm) < SnapShortcutRailView.step)

        // …but mid-flight safe-area churn (insets far past any real nav
        // clearance, re-propagated while the cell rides a transition) is
        // rejected: the rail's frame holds still so icons ride the page
        // instead of drifting toward the screen's safe boundary.
        chrome.setFixedInsets(UIEdgeInsets(top: 420, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        #expect(rail.frame.minY == settledMinY)
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

    /// The reactions rail is FORMAT-AGNOSTIC chrome — it persists on a
    /// text-only post exactly as on media (the shared action column the
    /// engaged layout floats over). The media danmaku surfaces (ticker,
    /// subtitle) still drop for text, but the rail stays and reserves its
    /// trailing exclusion column.
    @Test func textOnlyPostsKeepTheReactionsRail() throws {
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
        chrome.layoutIfNeeded()
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        #expect(rail.isHidden == false)
        #expect(chrome.railExclusionWidth > 0)
    }
}
