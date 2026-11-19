import CoreModels
import CoreNavigation
import DesignSystem
import LaunchArguments
import PostSurfaces
import ThreadKit
import Transitions
import UIKit

/// What the full-screen feed's page drive and pull-to-close ask of their
/// screen (#2387): the pager they move, where the comments engagement and
/// the settled page stand, and the vertical drag router's answer.
@MainActor
protocol SnapPagerDriveHost: AnyObject {
    /// The pager (the screen's collection view) the drive hand-moves.
    var pager: UIScrollView { get }
    /// The screen's view: the pull's indicator rides in it.
    var pagerHostView: UIView { get }
    var navigationController: UINavigationController? { get }
    var orderedIDs: [PostID] { get }
    /// The post whose comments engagement is active: only an engaged page
    /// drives.
    var commentsEngagedID: PostID? { get }
    var isKeyboardOnScreen: Bool { get }
    var settledPageIndex: Int { get }
    var activePostID: PostID? { get }
    /// `SnapVerticalDragRouter`'s owner of a downward drag beginning now.
    var downwardDragOwner: SnapVerticalDragRouter.DownwardOwner { get }
    /// The shown page's comment composer, which a still text page's pull
    /// indicator floats above.
    var pullComposerBar: UIView? { get }
    func displayModel(for id: PostID) -> FeedItemDisplayModel?
    /// The ceiling the drive clamps to — prepares the next page, then answers.
    func reachableCeiling() -> Int
    func isPageReady(_ index: Int) -> Bool
    func isTextPage(_ id: PostID?) -> Bool
    func prewarmRestingComments(for id: PostID)
    func setEngagedChrome(_ engaged: Bool, hasMedia: Bool, animated: Bool)
    /// The settle's landing: the active item, recomputed.
    func updateActiveItem()
}

/// The full-screen feed's page drive and its pull-to-close (#2387),
/// together because each gates the other: a drive stands down for a close
/// under way (`pageDriveYieldsToClose`), and a pull starts from where a drive
/// that began on the same drag left the page (`pullToClose`).
///
/// The arithmetic is `SnapPageDrive`'s and the direction of a downward drag
/// is `SnapVerticalDragRouter`'s (`downwardDragOwner`): this grows no
/// direction branch of its own. Every entry point runs in the caller's turn.
@MainActor
final class SnapPagerDrive {
    private unowned let host: any SnapPagerDriveHost

    /// The pager's `contentOffset.y` captured when an interactive page-swipe
    /// begins — the datum the drive offsets from. Nil when no drive is
    /// live. The drive hand-moves `contentOffset` while the pager's own pan
    /// stays disabled (the dead-end lock is untouched), so the finger
    /// drives the leaving page directly and the engaged layer (all in the
    /// cell) rides for free.
    private var pageDriveStartOffset: CGFloat?
    /// Where a page-change animation started, for as long as it is running.
    /// Nil at rest — see `isPostOnScreen`.
    private(set) var settleFromOffset: CGFloat?
    /// The pull-to-close under way on a native push (#2045, #2046): where the
    /// page rested, and the indicator in the gap it opens.
    private var pullBaseOffset: CGFloat?
    private(set) var pullIndicator: PullToGoBackIndicator?
    /// Whether the pull under way lifts the page: a media page's does; a text
    /// page's lifts nothing (#2187), read once at the pull's first step.
    private var pullLiftsPage = true

    init(host: any SnapPagerDriveHost) {
        self.host = host
    }

    /// Forgets a drive under way — a repoint resets the pager under it.
    func dropPageDrive() {
        pageDriveStartOffset = nil
    }

    // MARK: - The page drive (#2056, #2058)

    /// The INTERACTIVE page-swipe drive (bar-owned pan → this). The finger
    /// hand-moves the pager's `contentOffset` in real time, so the leaving
    /// page — and the whole engaged layer riding inside its cell (docked
    /// media card, comments, composer) — follows the drag exactly as if the
    /// user were swiping the feed itself. The pager's OWN pan stays disabled
    /// throughout (the dead-end lock is preserved: the comments list still
    /// cannot chain), because programmatic `contentOffset` ignores
    /// `isScrollEnabled`. On release the drive settles to the target page;
    /// the page change tears the old engagement down via the resign leg.
    func drivePageSwipe(
        _ phase: CommentsInputBar.PageSwipePhase, translation dy: CGFloat, velocity vy: CGFloat
    ) {
        #if DEBUG
        // `-grab-log`: the ONLY gesture that pages a text post, and its ceiling.
        //
        // A text page disables the pager outright, so nothing else on that
        // screen can move it. When it does not move, the question is whether
        // this ran at all and what it was allowed to reach — two answers no
        // other trace carries.
        if LaunchArgument.grabLog.isPassed() {
            print("[drive] \(phase) dy=\(Int(dy)) ceiling=\(host.reachableCeiling())"
                + " settled=\(host.settledPageIndex) engaged=\(host.commentsEngagedID?.rawValue ?? "nil")")
        }
        #endif
        switch phase {
        case .began: beginPageDrive()
        case .changed: updatePageDrive(translation: dy)
        case .ended: endPageDrive(translation: dy, velocity: vy)
        }
    }

    /// ⚠️ A PAGE DRIVE STANDS DOWN FOR THE CLOSE (#770): at the last post the
    /// upward close claims the drive's own drags (`upwardCloseTerritory`), and
    /// the two would otherwise move the page at once. The close's pop is
    /// running from the moment it begins — THIS stack's pop, not a sheet
    /// presented or dismissed over the feed (`isTransitioningItsStack`).
    private var pageDriveYieldsToClose: Bool {
        // A pop under way — or, on a native push, a pull, which starts no pop
        // (#2045, #2046).
        host.navigationController?.isTransitioningItsStack == true || pullBaseOffset != nil
    }

    private func beginPageDrive() {
        guard host.commentsEngagedID != nil, !pageDriveYieldsToClose else { return }
        // Interrupt any in-flight settle: seize the CURRENT on-screen offset
        // (presentation layer) so a re-grab mid-settle doesn't jump.
        let live = host.pager.layer.presentation()?.bounds.origin.y ?? host.pager.contentOffset.y
        host.pager.layer.removeAllAnimations()
        host.pager.contentOffset.y = live
        pageDriveStartOffset = live
    }

    private func updatePageDrive(translation dy: CGFloat) {
        guard let start = pageDriveStartOffset else { return }
        if pageDriveYieldsToClose {
            // The same drag is closing the screen: the page goes back where
            // it was, and the release settles nothing.
            host.pager.contentOffset.y = start
            pageDriveStartOffset = nil
            return
        }
        // Drag up (dy < 0) advances toward the next post (offset grows);
        // drag down previews the PREVIOUS one (#2058), down to the first post,
        // past which the drive rubber-bands (`SnapPageDrive.floorIndex`).
        let page = host.pager.bounds.height
        let origin = page > 0 ? Int((start / page).rounded()) : 0
        let floor = CGFloat(SnapPageDrive.floorIndex(origin: origin)) * page
        // The previous page made ready as the finger heads to it: the warm
        // holds one panel, the next page's until now (`reachableCeiling`).
        if dy > 0, origin > 0, !host.isPageReady(origin - 1) {
            host.prewarmRestingComments(for: host.orderedIDs[origin - 1])
        }
        host.pager.contentOffset.y = rubberBandedOffset(start - dy, floor: floor)
    }

    /// - Parameters:
    ///   - step: the step to settle, decided by the caller (a committed pull,
    ///     #2298); nil for the drag's own (`SnapPageDrive.step`).
    ///   - reducesMotion: the settle without its spring (a pull's commit
    ///     under Reduce Motion).
    ///   - completion: once the settle has ended, whatever it did.
    private func endPageDrive(
        translation dy: CGFloat, velocity vy: CGFloat, step decided: Int? = nil, reducesMotion: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let start = pageDriveStartOffset else { completion?(); return }
        pageDriveStartOffset = nil
        let page = host.pager.bounds.height
        guard page > 0 else { completion?(); return }
        let startIndex = Int((start / page).rounded())
        let step = decided ?? SnapPageDrive.step(translation: dy, velocity: vy, page: page)
        let target = SnapPageDrive.target(origin: startIndex, step: step, ceiling: host.orderedIDs.count - 1)
        let targetOffset = CGFloat(target) * page
        // FOOTER MORPH, timed with the settle: if this drive commits to a
        // page that will NOT re-engage into the sort toolbar — i.e. a media
        // post (text posts auto-engage and keep the engaged items) — the
        // engaged→default toolbar swap must animate HERE, concurrently with
        // the page slide, exactly as `dismissComments` does. Otherwise the
        // only teardown swap is `finishCommentsDisengagement`'s instant one,
        // which snaps (visible only forward, Text→Media). Its identity-
        // compare then no-ops once this animated swap has landed default.
        let changesPage = step != 0 && target != startIndex
        let targetReEngages = host.orderedIDs.indices.contains(target)
            && host.isTextPage(host.orderedIDs[target])
        if changesPage && !targetReEngages {
            host.setEngagedChrome(false, hasMedia: true, animated: true)
        }
        #if DEBUG
        // `-grab-log`: what the drive resolved to, and what the scroll view
        // will actually accept. A committed step that never moves the page is
        // either a target nobody applied or an offset something else is
        // holding, and the two look identical from outside.
        if LaunchArgument.grabLog.isPassed() {
            print("[drive] commit start=\(Int(start)) step=\(step) target=\(target)"
                + " targetY=\(Int(targetOffset)) offsetY=\(Int(host.pager.contentOffset.y))"
                + " contentH=\(Int(host.pager.contentSize.height))"
                + " pageH=\(Int(page)) scrollEnabled=\(host.pager.isScrollEnabled)")
        }
        #endif
        // The page being left is on screen for the whole of this animation,
        // whatever the model says — see `isPostOnScreen`.
        settleFromOffset = host.pager.contentOffset.y
        let distance = abs(host.pager.contentOffset.y - targetOffset)
        let springVelocity = distance > 0 ? min(3, abs(vy) / distance) : 0
        let settle = { self.host.pager.contentOffset.y = targetOffset }
        let settled: (Bool) -> Void = { [weak self] finished in
            #if DEBUG
            if LaunchArgument.grabLog.isPassed(), let self {
                print("[drive] settled finished=\(finished)"
                    + " offsetY=\(Int(host.pager.contentOffset.y))")
            }
            #endif
            self?.settleFromOffset = nil
            defer { completion?() }
            guard finished else { return }
            // Now the target page is settled: recompute the active item,
            // which fires the resign→teardown / activate legs (the landed
            // page auto-engages if it's a text post; the old engagement is
            // torn down as it resigns).
            self?.host.updateActiveItem()
        }
        if reducesMotion {
            UIView.animate(
                withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                animations: settle, completion: settled
            )
        } else {
            UIView.animate(
                withDuration: 0.4, delay: 0,
                usingSpringWithDamping: 0.9, initialSpringVelocity: springVelocity,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: settle, completion: settled
            )
        }
    }

    // MARK: - The pull to the next / previous post (#2298 § 2)

    /// Where a text page's pull goes (#2298 § 2): the post that way, as its
    /// pill shows it — nil when there is nowhere to go, so no pill. The page
    /// must be the settled one, at rest, with no close under way:
    /// - `.next`: the page after it, made ready as the pull begins (the
    ///   ceiling prepares it); none on the feed's last post (its upward close,
    ///   #628, stays as it is);
    /// - `.previous`: the router's answer (`downwardDragOwner`), so the first
    ///   post keeps its close (#2058) and shows no pill.
    func postPullTarget(_ direction: PostPullDirection, from id: PostID) -> PostPullTarget? {
        guard host.commentsEngagedID == id, !pageDriveYieldsToClose, !host.isKeyboardOnScreen,
              let index = host.orderedIDs.firstIndex(of: id), index == host.settledPageIndex else { return nil }
        let target: Int
        switch direction {
        case .next:
            guard host.reachableCeiling() > index else { return nil }
            target = index + 1
        case .previous:
            guard index > 0, host.downwardDragOwner == .pager else { return nil }
            target = index - 1
        }
        guard let model = host.displayModel(for: host.orderedIDs[target]) else { return nil }
        return PostPullTarget(
            authorName: model.authorName, monogram: CommentsInputBar.monogram(model.authorName),
            avatarURL: model.avatarURL
        )
    }

    /// A committed pull (or the page's VoiceOver action): the feed's own page
    /// change — the drive's settle, the composer's swipe's — from where the
    /// page stands, one step that way at the finger's velocity. Under Reduce
    /// Motion, the settle without its spring.
    func commitPostPull(
        _ direction: PostPullDirection, from id: PostID, velocity vy: CGFloat, completion: @escaping () -> Void
    ) {
        guard postPullTarget(direction, from: id) != nil else { return completion() }
        beginPageDrive()
        guard pageDriveStartOffset != nil else { return completion() }
        let step = direction == .next ? 1 : -1
        // The finger's velocity, only where it heads the page's way: a
        // release drifting back starts the settle from rest.
        let heading = direction == .next ? min(0, vy) : max(0, vy)
        let travel = CGFloat(-step) * host.pager.bounds.height
        endPageDrive(
            translation: travel, velocity: heading, step: step,
            reducesMotion: MotionPreference.reducesMotion, completion: completion
        )
    }

    /// UIScrollView-style rubber-band past `floor`/last page: the drive
    /// resists beyond the ends so you cannot fling off the feed — `floor` is
    /// the previous post (`SnapPageDrive.floorIndex`), the first one at most.
    private func rubberBandedOffset(_ offset: CGFloat, floor: CGFloat) -> CGFloat {
        let page = host.pager.bounds.height
        guard page > 0 else { return offset }
        let maxOffset = CGFloat(host.reachableCeiling()) * page
        if offset < floor { return floor - Self.rubberBand(floor - offset, dimension: page) }
        if offset > maxOffset { return maxOffset + Self.rubberBand(offset - maxOffset, dimension: page) }
        return offset
    }

    /// The standard iOS rubber-band curve: `(1 − 1/(x·c/d + 1))·d`. It maps
    /// [0, ∞) into [0, d) — monotonically increasing, always resisting (the
    /// mapped excess is strictly less than the raw excess), zero at zero.
    /// Internal for the pure-logic test.
    static func rubberBand(_ x: CGFloat, dimension d: CGFloat) -> CGFloat {
        (1 - 1 / (x * 0.55 / d + 1)) * d
    }

    // MARK: - The pull to go back (#2045, #2046)

    /// On a feed that came in with the native push, a vertical close is a pull:
    /// on a MEDIA page only the page's content moves — with the end of the list's
    /// own rubber band — under a navigation bar that stays, over the feed's own
    /// ground. No map, no dim, no parallax. The indicator rides in the gap: at the
    /// bottom for a page pulled up, under the bar for one pulled down. (In the
    /// back chevron instead was tried on the owner's device, 2026-11-05, and set
    /// aside: the native item stays.)
    ///
    /// ⚠️ A TEXT page lifts NOTHING (#2187, the owner): its text and comments
    /// are a reading surface, and a lift past the end read as a scroll gone too
    /// far. The page, its comments and its composer stay still; the indicator
    /// alone answers the finger, pinned where it sits at zero lift (over the
    /// composer, under the bar). The effort is the same: the progress is still
    /// the rubber-banded travel, it just drives no offset.
    @discardableResult
    func pullToClose(travel: CGFloat, along axis: ZoomDismissAxis) -> CGFloat {
        let view = host.pagerHostView
        let base: CGFloat
        if let pullBaseOffset {
            base = pullBaseOffset
        } else {
            // Where the page rested: a page drive that began on the same drag
            // has already moved it a little.
            base = pageDriveStartOffset ?? host.pager.contentOffset.y
            pullBaseOffset = base
            pullLiftsPage = !host.isTextPage(host.activePostID)
            let indicator = PullToGoBackIndicator(direction: axis == .upward ? .up : .down)
            indicator.prepare()
            view.addSubview(indicator)
            pullIndicator = indicator
        }
        let lift = Self.rubberBand(travel, dimension: max(1, view.bounds.height))
        if pullLiftsPage {
            host.pager.contentOffset.y = axis == .upward ? base + lift : base - lift
        } else if host.pager.contentOffset.y != base {
            // A page drive that began on the same drag may have nudged it:
            // a text page rests exactly where it was.
            host.pager.contentOffset.y = base
        }
        placePullIndicator(lift: pullLiftsPage ? lift : 0, axis: axis)
        pullIndicator?.setPull(lift)
        return lift
    }

    func endPullToClose(commit: Bool) {
        guard let base = pullBaseOffset else { return }
        pullBaseOffset = nil
        let indicator = pullIndicator
        pullIndicator = nil
        // Past the threshold the page leaves AS IT IS, lifted, with its
        // indicator — no drop back first, no diagonal.
        guard !commit else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { indicator?.removeFromSuperview() }
            return
        }
        UIView.animate(
            withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.host.pager.contentOffset.y = base
            indicator?.alpha = 0
        } completion: { _ in indicator?.removeFromSuperview() }
    }

    /// Pinned to the chrome, in the gap: over the toolbar for a page lifted
    /// from the bottom, under the bar for a page pulled down — it never rides
    /// the lift behind either (the owner's recording, 2026-11-05).
    ///
    /// A still text page (#2187) opens no gap: pulled up, the indicator floats
    /// over the comments just above the page's own composer — over the toolbar
    /// it sat ON the field, its label cut, on the simulator.
    private func placePullIndicator(lift: CGFloat, axis: ZoomDismissAxis) {
        guard let indicator = pullIndicator else { return }
        let view = host.pagerHostView
        let width = view.bounds.width - 2 * Spacing.lg
        let size = indicator.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let centreY: CGFloat
        if axis == .upward {
            let pageBottom = view.bounds.maxY - lift
            var toolbarTop = pullChromeEdge(bottom: true) ?? view.bounds.maxY - view.safeAreaInsets.bottom
            if !pullLiftsPage, let composerTop = pullComposerTop() {
                toolbarTop = min(toolbarTop, composerTop)
            }
            centreY = min(toolbarTop - size.height / 2 - Spacing.sm, (pageBottom + toolbarTop) / 2)
        } else {
            let barBottom = pullChromeEdge(bottom: false) ?? view.safeAreaInsets.top
            centreY = max(barBottom + size.height / 2 + Spacing.sm, lift / 2 + barBottom / 2)
        }
        indicator.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        indicator.center = CGPoint(x: view.bounds.midX, y: centreY)
    }

    /// The top of the shown page's comment composer, in the page's space.
    private func pullComposerTop() -> CGFloat? {
        guard let bar = host.pullComposerBar,
              bar.window != nil, !bar.isHidden, bar.alpha > 0.01, bar.bounds.height > 0 else { return nil }
        return bar.convert(bar.bounds, to: host.pagerHostView).minY
    }

    /// The navigation bar's bottom, or the shown toolbar's top, in the
    /// page's space.
    private func pullChromeEdge(bottom: Bool) -> CGFloat? {
        guard let nav = host.navigationController else { return nil }
        if bottom {
            guard !nav.isToolbarHidden, nav.toolbar.window != nil, nav.toolbar.bounds.height > 0 else { return nil }
            return nav.toolbar.convert(nav.toolbar.bounds, to: host.pagerHostView).minY
        }
        return nav.navigationBar.convert(nav.navigationBar.bounds, to: host.pagerHostView).maxY
    }
}
