import UIKit

/// ⚠️ THE FADE UNDER A TITLED BAR, AND THE SPACE A SCREEN'S CONTENT KEEPS
/// FROM IT AT REST (#2240, the owner 2026-11-10, on Relationships: "the blur
/// reaches over the first row").
///
/// UIKit's soft top-edge effect (`prefersSoftTopEdge`, the titled header's
/// blur since #1591) is the bar's height PLUS a fade below it. A plain list
/// starts right at the bar's bottom — the standard safe-area inset — so at
/// rest its first row sat in that fade, its face and name softened, though
/// nothing had scrolled under the bar yet. The blur is meant for content
/// that scrolls under the bar, and only that.
///
/// So the titled contract adds to the scroll view's `contentInset.top` what
/// its first content lacks to start below the fade: the whole fade for a
/// plain list, less for a list whose own top padding (a grouped section's,
/// a section title's) already covers part of it, nothing for one that
/// clears it. Every titled screen gets it from the one call it already
/// makes, and a new one gets it by adopting the contract.
///
/// Why `contentInset`, and what it leaves alone:
/// - **A status-bar tap** scrolls to `-adjustedContentInset.top`, which
///   counts it: the list comes back to the same rest, below the fade.
/// - **The scroll indicator** is inset by the safe area, not by
///   `contentInset`: its top does not move.
/// - **The pull-to-refresh** measures its pull from that same rest
///   (`AppRefreshControl`, UIKit's own threshold): the threshold does not
///   move.
/// - **Skeleton rows that are cells** move with the rows they stand for. A
///   skeleton that is a SIBLING of the list (Notifications) moves by the
///   same amount, using `SoftTopEdge.clearance(below:)`.
public enum SoftTopEdge {
    /// How far the soft top-edge effect reaches below the bar's bottom, in
    /// points: the ONE place the length is read from.
    ///
    /// ⚠️ NOT PUBLIC API: UIKit takes only a style, never a length. 40 is
    /// what the effect views measured past their edge in this repo's probes
    /// — MapKit's own soft `ScrollEdgeEffectView`, 156 pt tall over a
    /// 116 pt status band + inline bar on a 17 Pro (2026-09-22), and a scroll
    /// view's effect over the 62 pt status band alone, 102 pt (2026-09-30).
    /// `-top-fade-trace` prints the effect's frame on any titled screen, to
    /// re-measure it on another system, device or title size; should it
    /// vary, it varies here.
    public static let fadeLength: CGFloat = 40

    /// What a scroll view needs added to its top so content starting
    /// `firstContentTop` points into its content, behind `inset` points of
    /// its own top inset, rests below the fade. Zero when it already does.
    public static func clearance(below firstContentTop: CGFloat, inset: CGFloat = 0) -> CGFloat {
        let reach: CGFloat = inset + max(0, firstContentTop)
        return max(0, (fadeLength - reach).rounded(.up))
    }

    /// `-top-fade-clearance-off`: the screens as they were before #2240, for
    /// a before/after comparison without another build.
    nonisolated static let isClearanceOff: Bool = DebugFlags.isOn("-top-fade-clearance-off")
}

public extension UIScrollView {
    /// What the titled contract added to `contentInset.top` so the first
    /// content rests below the soft fade (#2240); zero when nothing was
    /// added. A sibling laid out where the rows will be reads it.
    var topFadeClearance: CGFloat { TopFadeClearanceKeeper.attached(to: self)?.applied ?? 0 }

    /// Keeps the first content below the soft fade at rest, without touching
    /// the edge effect itself — `prefersSoftTopEdge` calls it, and a pager
    /// that carries the blur calls it on the lists it hosts. Idempotent.
    internal func installTopFadeClearance() {
        if let keeper = TopFadeClearanceKeeper.attached(to: self) {
            keeper.update()
            return
        }
        let keeper = TopFadeClearanceKeeper(scrollView: self)
        TopFadeClearanceKeeper.remember(keeper, on: self)
        keeper.update()
    }
}

/// Holds one scroll view's clearance: measures its first content when its
/// content size or its inset changes, and keeps the extra top inset at what
/// that content lacks.
@MainActor
final class TopFadeClearanceKeeper: NSObject {
    private weak var scrollView: UIScrollView?
    /// What is in `contentInset.top` on the contract's behalf.
    private(set) var applied: CGFloat = 0
    /// `contentInset.top` after the keeper's last write: a different value
    /// means the screen assigned its own inset since, which does not carry
    /// the clearance any more.
    private var writtenTop: CGFloat?
    private var isWriting = false
    private var isRemeasureScheduled = false
    private var sizeObservation: NSKeyValueObservation?
    private var insetObservation: NSKeyValueObservation?

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
        // The content size changes when the content is laid out: the first
        // layout, a load, a section appearing.
        sizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.update()
                self?.scheduleRemeasureIfFramesLag()
            }
        }
        // A screen that assigns its own top inset AFTER the contract (the
        // wallet's lists, the post detail's stream shape) would otherwise
        // drop the clearance without anyone noticing.
        insetObservation = scrollView.observe(\.contentInset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isWriting else { return }
                self.update()
            }
        }
    }

    private enum Association {
        /// ⚠️ ITS ADDRESS IS THE KEY, NOT ITS VALUE (see `PressFeedback`).
        nonisolated(unsafe) static var key: UInt8 = 0
    }

    static func attached(to scrollView: UIScrollView) -> TopFadeClearanceKeeper? {
        objc_getAssociatedObject(scrollView, &Association.key) as? TopFadeClearanceKeeper
    }

    static func remember(_ keeper: TopFadeClearanceKeeper, on scrollView: UIScrollView) {
        objc_setAssociatedObject(scrollView, &Association.key, keeper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Brings the clearance to what the first content lacks now.
    func update() {
        guard let scrollView, !isWriting else { return }
        // Measured once on screen: off it, the screen holding the list (and
        // whether it rests on a large title) isn't known yet, and a value
        // written then and taken back on arrival moved a large-titled list's
        // rest (seen on the simulator). The arrival's layout measures it,
        // before the first frame is drawn.
        guard scrollView.window != nil else { return }
        // ⚠️ NEVER UNDER A REFRESH: the list is held open by the control's
        // own inset then, and a change of ours would fight its fold-back.
        // The next content change measures again.
        if scrollView.refreshControl?.isRefreshing == true { return }
        if let writtenTop, abs(scrollView.contentInset.top - writtenTop) > 0.5 {
            // The screen's own assignment: the value there is its base.
            applied = 0
            self.writtenTop = nil
        }
        let base: CGFloat = scrollView.contentInset.top - applied
        // Nothing laid out yet reads as a plain list's first row, at the
        // very top: the clearance is in place before the first frame, and
        // a list whose content turns out to clear the fade gives it back
        // at its first layout, before it is drawn.
        let first: CGFloat = Self.firstContentTop(in: scrollView, within: SoftTopEdge.fadeLength) ?? 0
        // ⚠️ NOT UNDER A LARGE TITLE: a screen resting on one (Settings, the
        // wallet's pages) starts its content below the title, far from the
        // fade, which only reaches the rows once the title has folded into
        // the bar — by scrolling, where it belongs (seen on the simulator:
        // 40 pt of empty space under "Notifications" when it took one).
        let restsOnLargeTitle: Bool = Self.restsOnLargeTitle(scrollView)
        let wanted: CGFloat = SoftTopEdge.isClearanceOff || restsOnLargeTitle
            ? 0 : SoftTopEdge.clearance(below: first, inset: base)
        #if DEBUG
        trace(scrollView, base: base, first: first, wanted: wanted)
        #endif
        guard abs(wanted - applied) > 0.5 else { return }
        // At rest stays at rest: UIKit leaves the offset where it was when
        // the inset grows, which would show the list scrolled by the
        // difference — the first row still in the fade.
        let wasAtRest = abs(scrollView.contentOffset.y + scrollView.adjustedContentInset.top) < 0.5
        isWriting = true
        UIView.performWithoutAnimation {
            scrollView.contentInset.top = base + wanted
            if wasAtRest, !scrollView.isTracking, !scrollView.isDecelerating {
                scrollView.contentOffset.y = -scrollView.adjustedContentInset.top
            }
        }
        isWriting = false
        applied = wanted
        writtenTop = scrollView.contentInset.top
    }

    /// Whether the screen holding `scrollView` shows a large title at rest:
    /// its navigation item, as the navigation controller holds it (a child's
    /// own item is not the one drawn), asks for one, or the bar prefers them
    /// and the item doesn't refuse.
    static func restsOnLargeTitle(_ scrollView: UIScrollView) -> Bool {
        var responder: UIResponder? = scrollView
        var screen: UIViewController?
        while let next = responder {
            if let controller = next as? UIViewController {
                screen = controller
                if controller.parent is UINavigationController || controller.parent == nil { break }
            }
            responder = next.next
        }
        guard let screen else { return false }
        switch screen.navigationItem.largeTitleDisplayMode {
        case .always: return true
        case .automatic: return screen.navigationController?.navigationBar.prefersLargeTitles == true
        default: return false
        }
    }

    /// A plain scroll view's content is its subviews, whose frames may be
    /// set after the content size in the same layout pass: measured again on
    /// the next turn. Lists answer from their layout, at once.
    private func scheduleRemeasureIfFramesLag() {
        guard let scrollView, !(scrollView is UICollectionView), !(scrollView is UITableView),
              !isRemeasureScheduled else { return }
        isRemeasureScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isRemeasureScheduled = false
            self?.update()
        }
    }

    /// Where the first content starts, in content coordinates — nil when
    /// there is none to measure yet. Content that starts at or past `depth`
    /// answers `depth`: it clears the fade, wherever it is.
    static func firstContentTop(in scrollView: UIScrollView, within depth: CGFloat) -> CGFloat? {
        if let collection = scrollView as? UICollectionView {
            return firstContentTop(in: collection, within: depth)
        }
        if let table = scrollView as? UITableView {
            return firstContentTop(in: table)
        }
        let tops: [CGFloat] = scrollView.subviews.compactMap { subview in
            guard isContent(subview) else { return nil }
            return subview.frame.minY
        }
        guard let top = tops.min() else { return nil }
        return max(0, top)
    }

    /// A collection view's first element of any kind — cell, header,
    /// decoration (a card's ground is content too) — from its layout.
    private static func firstContentTop(in collection: UICollectionView, within depth: CGFloat) -> CGFloat? {
        guard collection.contentSize.height > 0 else { return nil }
        let width: CGFloat = max(collection.bounds.width, collection.contentSize.width, 1)
        let probe = CGRect(x: 0, y: 0, width: width, height: depth)
        let elements = collection.collectionViewLayout.layoutAttributesForElements(in: probe) ?? []
        let tops: [CGFloat] = elements.compactMap { element in
            guard !element.isHidden, element.alpha > 0.01, element.frame.height > 0 else { return nil }
            return element.frame.minY
        }
        guard let top = tops.min() else { return depth }
        return max(0, top)
    }

    /// A table's header view, else its first section's: a plain table's
    /// section header, then its first row. A grouped table's header band is
    /// its section padding, so its first row is what counts.
    private static func firstContentTop(in table: UITableView) -> CGFloat? {
        if let header = table.tableHeaderView, !header.isHidden, header.bounds.height > 0 {
            return max(0, header.frame.minY)
        }
        for section in 0..<table.numberOfSections {
            if table.style == .plain {
                let header = table.rectForHeader(inSection: section)
                if header.height > 0 { return max(0, header.minY) }
            }
            if table.numberOfRows(inSection: section) > 0 {
                return max(0, table.rectForRow(at: IndexPath(row: 0, section: section)).minY)
            }
        }
        return nil
    }

    /// A subview that is the screen's content: shown, sized, and not one of
    /// UIKit's own (the scroll indicators, the edge effects, the refresh
    /// control).
    private static func isContent(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.01, view.bounds.height > 0, !(view is UIRefreshControl) else {
            return false
        }
        return !NSStringFromClass(type(of: view)).hasPrefix("_")
    }

    #if DEBUG
    /// One line per scroll view, then one per change.
    private var hasTraced = false

    /// `-top-fade-trace` (#2240): per titled scroll view, where its first
    /// content sits against the fade, the clearance, and — a second later,
    /// once drawn — the frames of the edge-effect views UIKit put around it,
    /// which is how the fade's length is measured. Run it with
    /// `-top-fade-clearance-off` for the "before" column of the audit.
    private func trace(_ scrollView: UIScrollView, base: CGFloat, first: CGFloat, wanted: CGFloat) {
        guard DebugFlags.isOn("-top-fade-trace"), !hasTraced || abs(wanted - applied) > 0.5 else { return }
        hasTraced = true
        let reach: CGFloat = base + first
        let inside = reach < SoftTopEdge.fadeLength ? "INSIDE" : "clear"
        print("[top-fade] \(Self.screenName(of: scrollView)) \(type(of: scrollView)) first=\(first) inset=\(base) "
            + "rest=\(reach) (\(inside) of \(SoftTopEdge.fadeLength)) clearance \(applied)→\(wanted) "
            + "safeTop=\(scrollView.safeAreaInsets.top)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak scrollView] in
            guard let scrollView, let window = scrollView.window else { return }
            let barBottom: CGFloat = scrollView.convert(CGPoint(x: 0, y: scrollView.bounds.minY), to: window).y
                + scrollView.safeAreaInsets.top
            var lines: [String] = []
            func walk(_ view: UIView, depth: Int) {
                let name = NSStringFromClass(type(of: view))
                if name.contains("EdgeEffect") || name.contains("Pocket") {
                    let frame = view.convert(view.bounds, to: window)
                    lines.append("\(name) y=\(frame.minY) h=\(frame.height) fade=\(frame.maxY - barBottom)")
                }
                guard depth > 0 else { return }
                view.subviews.forEach { walk($0, depth: depth - 1) }
            }
            walk(scrollView.superview ?? scrollView, depth: 4)
            print("[top-fade] \(Self.screenName(of: scrollView)) barBottom=\(barBottom) effects: "
                + (lines.isEmpty ? "none found" : lines.joined(separator: " | ")))
        }
    }

    private static func screenName(of view: UIView) -> String {
        var responder: UIResponder? = view
        while let next = responder {
            if let controller = next as? UIViewController { return String(describing: type(of: controller)) }
            responder = next.next
        }
        return "?"
    }
    #endif
}
