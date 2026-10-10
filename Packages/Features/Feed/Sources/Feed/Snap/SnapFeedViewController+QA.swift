#if DEBUG
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// MARK: - QA hooks
//
// Test seams, launch-argument drivers and probes that read nothing private
// beyond the few members widened for them. The launch-argument hooks that
// drive the screen (`runDebugAppearanceHooks`) stay in
// `SnapFeedViewController.swift`, and so do the comments, loading-page and
// dismissal accessors and the `ArrivalInvariantReporting` facts: each reads
// private state that a file of its own could only reach by widening it.

// MARK: - Bar

extension SnapFeedViewController {
    func dumpBarHierarchy() {
        guard let nav = navigationController else { return }
        func walk(_ view: UIView, _ depth: Int) {
            let f = view.frame
            print("BARDUMP:\(String(repeating: "  ", count: depth))\(type(of: view)) "
                + "frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))) "
                + "alpha=\(String(format: "%.2f", view.alpha))\(view.isHidden ? " HIDDEN" : "")")
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(nav.view, 0)
        func chainDescription(from view: UIView?) -> String {
            var chain: [String] = []
            var current: UIView? = view
            while let view = current {
                let id = String(UInt(bitPattern: ObjectIdentifier(view).hashValue) % 0xFFFF, radix: 16)
                chain.append("\(type(of: view))#\(id)")
                current = view.superview
            }
            return chain.joined(separator: " -> ")
        }
        for (index, item) in (toolbarItems ?? []).enumerated() where item.customView != nil {
            print("BARDUMP:CHAIN toolbarItem[\(index)]: " + chainDescription(from: item.customView))
        }
        print("BARDUMP:CHAIN navTrailing: " + chainDescription(from: navigationItem.rightBarButtonItem?.customView))
        print("BARDUMP:CHAIN navLeading: " + chainDescription(from: navigationItem.leftBarButtonItem?.customView))
    }

    /// `-pill-probe`: the WRAPPER'S width against the pill's fixed one, a
    /// moment after each content swap has landed (the bar's own pass has run
    /// by then).
    ///
    /// ⚠️ This used to be a guard, not a probe: a kept bar item hosts its view
    /// in a UIKit wrapper whose width was measured DRIFTING from the view's
    /// (memory `bar-item-wrapper-drift`: +9pt per round trip, cumulative, until
    /// the bar folded a group into `•••`), and while the pills hugged their
    /// text every swap was a new width to drift from, so a >1pt disagreement
    /// re-minted the item. The pills' widths no longer move with a post
    /// (`applyBarPillWidths`), which leaves the wrapper nothing to drift from;
    /// the probe stays so a `DRIFT` line would say so if it ever came back.
    func debugProbeBarItemWidth(_ pill: UIView, slot: String) {
        guard ProcessInfo.processInfo.arguments.contains("-pill-probe") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak pill] in
            guard let pill, pill.window != nil else { return }
            let fixed = (pill as? SnapAuthorIdentityView)?.fixedWidth
                ?? (pill as? SnapMediaAttributionView)?.fixedWidth ?? -1
            let drawn = pill.bounds.width
            let wrapper = pill.superview?.bounds.width ?? -1
            let drifted = abs(drawn - fixed) > 1 || abs(wrapper - drawn) > 1
            print(String(format: "[pill-probe] width %@ fixed=%.1f view=%.1f wrapper=%.1f%@",
                         slot, fixed, drawn, wrapper, drifted ? " DRIFT" : ""))
        }
    }
}

// MARK: - Pager drives

extension SnapFeedViewController {
    /// Walks the page swipe a finger drives on a text page, animated settle
    /// included.
    ///
    /// The only gesture that moves a text page belongs to the composer bar, and
    /// a synthetic drag cannot produce it — so the window that matters most
    /// here, the half-second while the settle animates and the model has
    /// already arrived at the destination, had no scripted route at all. Every
    /// defect reported inside it had to be found by watching a recording.
    func debugDrivePageSwipe(steps: Int = 12, distance: CGFloat = 520) {
        drivePageSwipe(.began, translation: 0, velocity: 0)
        for step in 1...max(1, steps) {
            let dy = -distance * CGFloat(step) / CGFloat(max(1, steps))
            drivePageSwipe(.changed, translation: dy, velocity: -900)
        }
        drivePageSwipe(.ended, translation: -distance, velocity: -900)
    }

    /// One page of scroll, in sixtieths of a second — a flick, not a jump.
    ///
    /// Each step is an ordinary offset change followed by the delegate callback
    /// UIKit would have sent, so everything that reacts to scrolling reacts
    /// here: the paging footer, and the page that owns the picture.
    ///
    /// ⚠️ WAITS FOR THE NEXT PAGE TO BE REACHABLE before it moves. The
    /// ceiling stops at the first page whose data has not arrived, so a fling
    /// fired at a fixed 3s on a cold run clamped to the page it started on:
    /// `target == start`, 24 steps of zero distance, and `[fling] begin` /
    /// `[fling] settle` printed exactly as for a real one — a run that scrolled
    /// nothing read as a pass. It now waits for `target > start`, and a page
    /// that never becomes reachable is a `[qa] GAVE UP`, never a fling.
    func debugFlingPages(_ remaining: Int) {
        guard remaining > 0 else { return }
        QAWait.until("-snap-fling (\(remaining) left)", { [weak self] in
            guard let self else { return false }
            let page = self.collectionView.bounds.height
            guard page > 0 else { return false }
            return CGFloat(self.reachableCeiling()) * page > self.collectionView.contentOffset.y + 0.5
        }) { [weak self] in
            self?.debugFlingOnePage(remaining)
        }
    }

    private func debugFlingOnePage(_ remaining: Int) {
        let page = collectionView.bounds.height
        let start = collectionView.contentOffset.y
        let target = min(start + page, CGFloat(reachableCeiling()) * page)
        // `-snap-fling-steps N`: frames per page, one every 1/60 s. 24 is a
        // gentle 0.4 s page; 3 is a fling (about 17,000 pt/s on a 874 pt
        // page), the speed #627 is about.
        var steps = 24
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-snap-fling-steps"), index + 1 < arguments.count,
           let asked = Int(arguments[index + 1]), asked > 0 {
            steps = asked
        }
        print("[fling] begin from=\(Int(start)) to=\(Int(target))")
        func step(_ index: Int) {
            guard index <= steps else {
                self.scrollViewDidEndDecelerating(self.collectionView)
                print("[fling] settle offsetY=\(Int(self.collectionView.contentOffset.y))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.debugFlingPages(remaining - 1)
                }
                return
            }
            let progress = CGFloat(index) / CGFloat(steps)
            collectionView.contentOffset.y = start + (target - start) * progress
            scrollViewDidScroll(collectionView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { step(index + 1) }
        }
        step(1)
    }
}

// MARK: - Page display

extension SnapFeedViewController {
    /// The moment a cell BEGINS displaying, through the delegate the app uses.
    ///
    /// ⚠️ Not `presentRestingComments` directly. The defect this exists for was
    /// a GATE at this call site, so a test that called the method underneath it
    /// proved the method right and the screen blank.
    func debugWillDisplayCell(at item: Int) {
        let path = IndexPath(item: item, section: 0)
        // Half a page in, which is where a real drag realizes it — a cell that
        // has not been built yet cannot be told it is about to display, and a
        // test that skipped that would assert about nothing.
        let page = collectionView.bounds.height
        if collectionView.cellForItem(at: path) == nil, page > 0 {
            collectionView.contentOffset.y = (CGFloat(item) - 0.5) * page
            collectionView.layoutIfNeeded()
        }
        guard let cell = collectionView.cellForItem(at: path) else { return }
        collectionView(collectionView, willDisplay: cell, forItemAt: path)
    }

    /// Tells the screen about every cell the layout has just realized, the way
    /// a real scroll does.
    ///
    /// A test moves `contentOffset` directly, and UIKit builds the cells but
    /// does not run the delegate's begin-displaying callback for them — which
    /// is where a page decides what to show. Without this a suite can only
    /// observe settled states, and four of the six defects in this area lived
    /// strictly between them.
    func debugRealizeVisibleCells() {
        for path in collectionView.indexPathsForVisibleItems.sorted() {
            guard let cell = collectionView.cellForItem(at: path) else { continue }
            collectionView(collectionView, willDisplay: cell, forItemAt: path)
        }
    }

    /// Which posts have a comments panel ON SCREEN right now, asked of the
    /// cells rather than of any bookkeeping.
    ///
    /// A specification for this screen has to be written against what the
    /// viewer sees: every defect here has been a disagreement between a field
    /// and the pixels, so a test that reads the field agrees with the bug.
    var debugPostsShowingComments: Set<PostID> {
        var showing: Set<PostID> = []
        for cell in collectionView.visibleCells {
            guard let path = collectionView.indexPath(for: cell),
                  orderedIDs.indices.contains(path.item),
                  let snap = cell as? SnapFeedCell, snap.isShowingComments else { continue }
            showing.insert(orderedIDs[path.item])
        }
        return showing
    }

    /// Whether the pager can be scrolled at all — the state a leaked
    /// engagement used to be able to hold down for the rest of a session.
    var debugPagerIsLocked: Bool { !collectionView.isScrollEnabled }

    /// The ceiling the pager actually clamps to — prepares, then answers.
    func debugReachableCeiling() -> Int { reachableCeiling() }

    /// The moment a page's last pixel leaves — which a unit test's scroll does
    /// not produce, and which is now when a resting page is torn down.
    func debugLeaveCell(at item: Int) {
        let path = IndexPath(item: item, section: 0)
        guard let cell = collectionView.cellForItem(at: path) else { return }
        collectionView(collectionView, didEndDisplaying: cell, forItemAt: path)
    }

    /// The post whose clip is running, read off the CELLS rather than from the
    /// index above: a dispatch that never reaches a cell starts nothing, and
    /// asking the bookkeeping would not know the difference.
    var debugPlayingPostID: PostID? {
        for (index, id) in orderedIDs.enumerated() {
            guard let cell = collectionView.cellForItem(
                at: IndexPath(item: index, section: 0)
            ) as? SnapFeedCell else { continue }
            if cell.debugOwnsPlayback { return id }
        }
        return nil
    }
}

// MARK: - Menu and reveal

extension SnapFeedViewController {
    /// Opens the masked window the comment-count path opens, without a
    /// transition to drive it — the state a settle must not paint over.
    func debugBeginMaskedReveal(for id: PostID) {
        openComments(for: id, revealingFrom: CGRect(x: 28, y: 601, width: 312, height: 195))
        setZoomContentHidden(true)
    }

    /// The ⋯ menu's rows, as built for `id`. The menu itself is a deferred
    /// element UIKit resolves when it opens, so there is nothing to read off
    /// the button — the composition has to be asked for.
    func debugMoreMenuActions(for id: PostID) -> [UIMenuElement] { moreMenuActions(for: id) }

    func debugMoreMenuTitles(for id: PostID) -> [String] {
        debugMoreMenuActions(for: id).compactMap { ($0 as? UIAction)?.title }
    }
}

// MARK: - Pages

extension SnapFeedViewController {
    /// How many pages the feed holds, for a test waiting on its first load.
    var debugPageCount: Int { orderedIDs.count }
    /// Whether a next page is on its way. Tests.
    var debugIsLoadingNextPage: Bool { viewModel.isLoadingNextPage }
}
#endif
