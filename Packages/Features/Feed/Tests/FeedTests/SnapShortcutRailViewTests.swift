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
            frame: CGRect(x: 0, y: 0, width: SnapShortcutRailView.railWidth, height: Self.railHeight)
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

    @Test func scrollPhysicsAreNative() {
        let rail = makeRail()
        // The wheel's motion is UIKit's, untouched. Detent snapping was
        // tried and retired: retargeting `targetContentOffset` lurched
        // low-velocity releases onto the grid (micro-jitter) and its
        // boundary-coincident detents deadened the edge spring. Any scroll
        // delegate or custom rate reappearing here is that regression.
        #expect(rail.delegate == nil)
        #expect(rail.decelerationRate == .normal)
        #expect(rail.bounces)
        #expect(rail.alwaysBounceVertical)
    }

    @Test func railPanTrapsVerticalTouchesFromTheFeed() {
        let rail = makeRail()
        let feedPan = UIPanGestureRecognizer()
        // Same-axis scroll chaining is severed: no simultaneity with the
        // pager's pan, and any other pan must wait for the rail's pan to
        // fail — a boundary overshoot rubber-bands instead of paging the
        // feed.
        #expect(rail.gestureRecognizer(rail.panGestureRecognizer, shouldRecognizeSimultaneouslyWith: feedPan) == false)
        #expect(rail.gestureRecognizer(rail.panGestureRecognizer, shouldBeRequiredToFailBy: feedPan) == true)
        // Non-pan recognizers (taps) are not held hostage by the wheel.
        #expect(rail.gestureRecognizer(rail.panGestureRecognizer, shouldBeRequiredToFailBy: UITapGestureRecognizer()) == false)
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

        // Trailing column: one bubble wide, Spacing.md off the margin
        // (no window → zero safe area → margins guide == bounds).
        #expect(rail.frame.width == SnapShortcutRailView.railWidth)
        #expect(rail.frame.maxX == 390 - Spacing.md)
        // Vertical span: under the nav bar down to the ticker's top edge.
        #expect(rail.frame.minY == Spacing.sm)
        #expect(rail.frame.maxY == ticker.frame.minY - Spacing.sm)
        // The subtitle zone stops short of the rail — the width reduction.
        #expect(subtitle.frame.maxX == rail.frame.minX - Spacing.md)
        // A media post shows its wheel.
        #expect(rail.isHidden == false)
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
