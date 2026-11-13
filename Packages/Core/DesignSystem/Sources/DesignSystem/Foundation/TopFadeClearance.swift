import LaunchArguments
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
    /// Where the soft top-edge effect's softening ENDS under an inline
    /// title, in points below the bar's bottom: the ONE place the length is
    /// read from (#2286).
    ///
    /// ⚠️ NOT PUBLIC API: UIKit takes only a style, never a length. Measured
    /// on the simulator (iPhone 18 Pro, iOS 27.0, light and dark alike: a
    /// blur, not a tint) with `-top-fade-lab`, a checkerboard run under the
    /// bar, the list scrolled under it. The contrast left, from the bar's
    /// bottom down:
    ///
    /// | Below the bar | 2 pt squares | 8 pt squares (text's scale) |
    /// |---|---|---|
    /// | 0 pt  | 18 % | 55 % |
    /// | 14 pt | 50 % | 76 % |
    /// | 24 pt | 72 % | 89 % |
    /// | 32 pt | 98 % | 99 % |
    ///
    /// 24 pt is where text-sized detail is back to ~90 %; the margin below
    /// takes the first ink past the last of it. #2240's 40 pt was the
    /// effect VIEW's frame (`-top-fade-trace` prints it), whose last points
    /// are transparent. Should it vary by system or device, it varies here.
    ///
    /// ⚠️ AT REST THE EFFECT IS OFF on a plain list (measured: the squares
    /// under the bar are sharp), and fully on from ~3 pt of scroll. The
    /// clearance is for that first moment, and for a host whose effect
    /// stays on at rest (a pager carrying it).
    public static let fadeLength: CGFloat = 24

    /// Under a search field stacked below the title (the inbox): the fade
    /// passes under the field itself. Measured 91 % sharp at the bar's
    /// bottom (2 pt squares), 99 % 4 pt below: the margin covers it.
    public static let fadeLengthUnderStackedSearch: CGFloat = 0

    /// The room kept between the fade's end and the first ink, so the first
    /// line reads as sharp rather than just out of the blur.
    public static let inkMargin: CGFloat = 4

    /// How deep, from the bar's bottom, the first ink must start at rest.
    public static var clearanceDepth: CGFloat { clearanceDepth(underStackedSearch: false) }

    /// The depth under a header with, or without, a stacked search field.
    public static func clearanceDepth(underStackedSearch: Bool) -> CGFloat {
        (underStackedSearch ? fadeLengthUnderStackedSearch : fadeLength) + inkMargin
    }

    /// What a scroll view needs added to its top so the first INK, starting
    /// `firstInkTop` points into its content behind `inset` points of its
    /// own top inset, rests below the fade and its margin. Zero when it
    /// already does.
    public static func clearance(below firstInkTop: CGFloat, inset: CGFloat = 0,
                                 underStackedSearch: Bool = false) -> CGFloat {
        let reach: CGFloat = inset + max(0, firstInkTop)
        return max(0, (clearanceDepth(underStackedSearch: underStackedSearch) - reach).rounded(.up))
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
    /// Whether the clearance was ever measured on drawn content (#2286):
    /// once it has, a pass whose first row isn't loaded (scrolled away)
    /// keeps it rather than falling back to the frame.
    private var hasMeasuredInk = false
    /// Laid out right after the scroll view, in the same pass: the cells a
    /// list made in its layout are there, configured, before the frame is
    /// drawn (see `TopFadeLayoutProbe`).
    private lazy var probe = TopFadeLayoutProbe { [weak self] in self?.update(isProbePass: true) }

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

    /// Brings the clearance to what the first content's ink lacks now.
    func update(isProbePass: Bool = false) {
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
        let underSearch: Bool = Self.restsUnderStackedSearch(scrollView)
        let depth: CGFloat = SoftTopEdge.clearanceDepth(underStackedSearch: underSearch)
        let measure = Self.firstInkTop(in: scrollView, within: depth)
        if measure.isPending {
            // The first element's view isn't made yet: its frame stands in
            // (its ink is never above it), and the probe measures the ink
            // later in this same layout pass, once the list made its cells.
            if !isProbePass { requestProbePass(on: scrollView) }
            // Scrolled away from the top, the first row isn't loaded: the
            // value its ink gave stays.
            if hasMeasuredInk { return }
        } else if measure.top != nil {
            hasMeasuredInk = true
        }
        let first: CGFloat = measure.top ?? 0
        // ⚠️ NOT UNDER A LARGE TITLE: a screen resting on one (Settings, the
        // wallet's pages) starts its content below the title, far from the
        // fade, which only reaches the rows once the title has folded into
        // the bar — by scrolling, where it belongs (seen on the simulator:
        // 40 pt of empty space under "Notifications" when it took one).
        let restsOnLargeTitle: Bool = Self.restsOnLargeTitle(scrollView)
        let wanted: CGFloat = SoftTopEdge.isClearanceOff || restsOnLargeTitle
            ? 0 : SoftTopEdge.clearance(below: first, inset: base, underStackedSearch: underSearch)
        #if DEBUG
        trace(scrollView, base: base, first: first, wanted: wanted, depth: depth)
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

    /// Asks for a measure after the scroll view's own layout, in the same
    /// pass (`TopFadeLayoutProbe`).
    private func requestProbePass(on scrollView: UIScrollView) {
        if probe.superview !== scrollView {
            // At the back: nothing reads it as the content's first subview's
            // successor, and it is never content (zero size, transparent).
            scrollView.insertSubview(probe, at: 0)
        }
        probe.setNeedsLayout()
    }

    /// Whether the screen holding `scrollView` shows a large title at rest:
    /// its navigation item, as the navigation controller holds it (a child's
    /// own item is not the one drawn), asks for one, or the bar prefers them
    /// and the item doesn't refuse.
    static func restsOnLargeTitle(_ scrollView: UIScrollView) -> Bool {
        guard let screen = screen(holding: scrollView) else { return false }
        switch screen.navigationItem.largeTitleDisplayMode {
        case .always: return true
        case .automatic: return screen.navigationController?.navigationBar.prefersLargeTitles == true
        default: return false
        }
    }

    /// Whether the screen holding `scrollView` stacks a search field under
    /// its title (the inbox, #1901): the fade passes under the field then.
    static func restsUnderStackedSearch(_ scrollView: UIScrollView) -> Bool {
        guard let item = screen(holding: scrollView)?.navigationItem, item.searchController != nil else {
            return false
        }
        return item.preferredSearchBarPlacement == .stacked
    }

    /// The screen a scroll view belongs to: the view controller the
    /// navigation controller holds (a child's own item is not the one
    /// drawn), else the topmost one found.
    private static func screen(holding scrollView: UIScrollView) -> UIViewController? {
        var responder: UIResponder? = scrollView
        var screen: UIViewController?
        while let next = responder {
            if let controller = next as? UIViewController {
                screen = controller
                if controller.parent is UINavigationController || controller.parent == nil { break }
            }
            responder = next.next
        }
        return screen
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

    /// Where the first content's INK starts, in content coordinates (#2286):
    /// what a row or a heading draws, not its frame, whose own blank padding
    /// (a row's avatar ~7 pt in, a heading's text at the bottom of its
    /// header) would count as content and push the list down for nothing.
    struct InkMeasure: Equatable {
        /// nil when there is no content to measure yet.
        var top: CGFloat?
        /// The first element's view isn't made yet: `top` is its frame's.
        var isPending = false
    }

    /// Content whose ink starts at or past `depth` answers `depth`: it
    /// clears the fade, wherever it is.
    static func firstInkTop(in scrollView: UIScrollView, within depth: CGFloat) -> InkMeasure {
        let ground: UIColor? = InkProbe.ground(of: scrollView)
        if let collection = scrollView as? UICollectionView {
            return firstInkTop(in: collection, within: depth, ground: ground)
        }
        if let table = scrollView as? UITableView {
            return firstInkTop(in: table, within: depth, ground: ground)
        }
        let content: [UIView] = scrollView.subviews.filter(isContent)
        guard !content.isEmpty else { return InkMeasure(top: nil) }
        let tops: [CGFloat] = content.compactMap { InkProbe.inkTop(of: $0, in: scrollView, ground: ground) }
        return InkMeasure(top: min(depth, max(0, tops.min() ?? depth)))
    }

    /// A collection view's elements of any kind near the top — cell, header,
    /// decoration (a card's ground is ink too) — each measured on its view
    /// when it is made, else on its frame.
    private static func firstInkTop(in collection: UICollectionView, within depth: CGFloat,
                                    ground: UIColor?) -> InkMeasure {
        guard collection.contentSize.height > 0 else { return InkMeasure(top: nil) }
        let width: CGFloat = max(collection.bounds.width, collection.contentSize.width, 1)
        let probe = CGRect(x: 0, y: 0, width: width, height: depth)
        let elements = collection.collectionViewLayout.layoutAttributesForElements(in: probe) ?? []
        var tops: [CGFloat] = []
        var isPending = false
        for element in elements {
            guard !element.isHidden, element.alpha > 0.01, element.frame.height > 0 else { continue }
            let view: UIView?
            switch element.representedElementCategory {
            case .cell: view = collection.cellForItem(at: element.indexPath)
            case .supplementaryView:
                view = element.representedElementKind.flatMap {
                    collection.supplementaryView(forElementKind: $0, at: element.indexPath)
                }
            default:
                // A decoration has no public view: one of ours is a ground (a
                // card's), ink from its top. UIKit's own list decorations are
                // not: the swipe actions' slot (a row's height at its top,
                // empty at rest) and the section's background colour (which
                // starts far above the content) — measured on the
                // relationships list, they put the "ink" at 0 (#2286).
                if Self.isSystemListDecoration(element.representedElementKind) { continue }
                tops.append(element.frame.minY)
                continue
            }
            guard let view else {
                isPending = true
                tops.append(element.frame.minY)
                continue
            }
            if let top = InkProbe.inkTop(of: view, in: collection, ground: ground) { tops.append(top) }
        }
        return InkMeasure(top: min(depth, max(0, tops.min() ?? depth)), isPending: isPending)
    }

    /// UIKit's own list layout decorations, which draw nothing at rest or
    /// are the list's ground: `UICollectionViewListLayoutElementKind…`,
    /// `_UICollectionView…`.
    static func isSystemListDecoration(_ kind: String?) -> Bool {
        guard let kind else { return false }
        return kind.hasPrefix("_UICollectionView") || kind.hasPrefix("UICollectionViewListLayoutElementKind")
    }

    /// A table's header view, then its sections: a section header (its text
    /// is the ink, grouped or plain), then its first row.
    private static func firstInkTop(in table: UITableView, within depth: CGFloat, ground: UIColor?) -> InkMeasure {
        var tops: [CGFloat] = []
        var isPending = false
        var hasContent = false
        if let header = table.tableHeaderView, !header.isHidden, header.bounds.height > 0 {
            hasContent = true
            if let top = InkProbe.inkTop(of: header, in: table, ground: ground) { tops.append(top) }
        }
        sections: for section in 0..<table.numberOfSections {
            let headerRect = table.rectForHeader(inSection: section)
            if headerRect.height > 0 {
                guard headerRect.minY < depth else { break sections }
                hasContent = true
                if let view = table.headerView(forSection: section) {
                    if let top = InkProbe.inkTop(of: view, in: table, ground: ground) { tops.append(top) }
                } else if table.style == .plain {
                    // A plain table's header is a view of its own, not made
                    // yet; a grouped one without a view is its padding.
                    isPending = true
                    tops.append(headerRect.minY)
                }
            }
            guard table.numberOfRows(inSection: section) > 0 else { continue }
            let indexPath = IndexPath(row: 0, section: section)
            let rowRect = table.rectForRow(at: indexPath)
            guard rowRect.minY < depth else { break sections }
            hasContent = true
            if let cell = table.cellForRow(at: indexPath) {
                if let top = InkProbe.inkTop(of: cell, in: table, ground: ground) { tops.append(top) }
            } else {
                isPending = true
                tops.append(rowRect.minY)
            }
            // The first row with ink settles it: what follows starts lower.
            if !tops.isEmpty { break sections }
        }
        guard hasContent else { return InkMeasure(top: nil) }
        return InkMeasure(top: min(depth, max(0, tops.min() ?? depth)), isPending: isPending)
    }

    /// A subview that is the screen's content: shown, sized, and not one of
    /// UIKit's own (the scroll indicators, the edge effects, the refresh
    /// control) nor the probe.
    private static func isContent(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.01, view.bounds.height > 0, !(view is UIRefreshControl),
              !(view is TopFadeLayoutProbe) else {
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
    private func trace(_ scrollView: UIScrollView, base: CGFloat, first: CGFloat, wanted: CGFloat, depth: CGFloat) {
        guard DebugFlags.isOn("-top-fade-trace"), !hasTraced || abs(wanted - applied) > 0.5 else { return }
        hasTraced = true
        let reach: CGFloat = base + first
        let inside = reach < depth ? "INSIDE" : "clear"
        // The audit's "before" (#2286): #2240 measured the first FRAME
        // against a 40 pt fade.
        let frameTop: CGFloat = Self.debugFirstFrameTop(in: scrollView) ?? 0
        let before: CGFloat = max(0, (40 - base - frameTop).rounded(.up))
        Self.log("[top-fade] \(Self.screenName(of: scrollView)) audit frameTop=\(frameTop) inkTop=\(first) "
            + "inset=\(base) before=\(before) after=\(wanted)")
        Self.log("[top-fade] \(Self.screenName(of: scrollView)) \(type(of: scrollView)) firstInk=\(first) inset=\(base) "
            + "rest=\(reach) (\(inside) of \(depth)) clearance \(applied)→\(wanted) "
            + "safeTop=\(scrollView.safeAreaInsets.top)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak scrollView] in
            guard let scrollView, let window = scrollView.window else { return }
            // The settled measure, and what the first row's ink stops on.
            let settled = Self.firstInkTop(in: scrollView, within: 60)
            let firstCell: UIView? = (scrollView as? UICollectionView).flatMap { list in
                list.visibleCells.min { $0.frame.minY < $1.frame.minY }
            } ?? (scrollView as? UITableView)?.visibleCells.min { $0.frame.minY < $1.frame.minY }
            let report: String = firstCell.map {
                InkProbe.debugInkReport(of: $0, in: scrollView, ground: InkProbe.ground(of: scrollView))
            } ?? "no cell"
            Self.log("[top-fade] \(Self.screenName(of: scrollView)) settled inkTop=\(settled.top ?? -1) "
                + "pending=\(settled.isPending) frameTop=\(Self.debugFirstFrameTop(in: scrollView) ?? -1) "
                + "inset=\(scrollView.contentInset.top) applied=\(TopFadeClearanceKeeper.attached(to: scrollView)?.applied ?? -1) "
                + "ink: \(report)")
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
            Self.log("[top-fade] \(Self.screenName(of: scrollView)) barBottom=\(barBottom) effects: "
                + (lines.isEmpty ? "none found" : lines.joined(separator: " | ")))
        }
    }

    /// Where the first element's FRAME starts, as #2240 measured it: the
    /// audit's "before" column.
    private static func debugFirstFrameTop(in scrollView: UIScrollView) -> CGFloat? {
        if let collection = scrollView as? UICollectionView {
            let width: CGFloat = max(collection.bounds.width, collection.contentSize.width, 1)
            let elements = collection.collectionViewLayout.layoutAttributesForElements(
                in: CGRect(x: 0, y: 0, width: width, height: 40)) ?? []
            return elements.filter { !$0.isHidden && $0.alpha > 0.01 && $0.frame.height > 0 }
                .map(\.frame.minY).min().map { max(0, $0) } ?? 40
        }
        if let table = scrollView as? UITableView {
            if let header = table.tableHeaderView, !header.isHidden, header.bounds.height > 0 {
                return max(0, header.frame.minY)
            }
            for section in 0..<table.numberOfSections {
                if table.style == .plain, table.rectForHeader(inSection: section).height > 0 {
                    return max(0, table.rectForHeader(inSection: section).minY)
                }
                if table.numberOfRows(inSection: section) > 0 {
                    return max(0, table.rectForRow(at: IndexPath(row: 0, section: section)).minY)
                }
            }
            return nil
        }
        return scrollView.subviews.filter(isContent).map(\.frame.minY).min().map { max(0, $0) }
    }

    /// NSLog, not print: `log show` reads it from a launched app.
    private static func log(_ line: String) { NSLog("%@", line) }

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
