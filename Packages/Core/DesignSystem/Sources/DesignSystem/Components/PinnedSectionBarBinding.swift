import UIKit

/// ⚠️ ONE CONTRACT BINDING A SCREEN'S SECTIONS TO A BAR ITEM (#1573, the owner
/// 2026-10-22): the section the list has scrolled into, named in the bar —
/// "New · 3", "Yesterday" — and a tap on it scrolls back to that section's
/// header. For You's pushed lists (#1378), the Messages inbox (#1301) and
/// the profile each wired this by hand; a screen now only describes its
/// sections and says where the item goes.
///
/// **The screen provides**: its sections (identifier, title, optional count)
/// and their tops in its scroll view, at every scroll (`update`) — or, for a
/// list that already works out its own pinned section because it names it
/// to several hosts (`ForYouGridPage`, the inbox's pages), that section
/// (`show(pinned:)`); and what a tap does (`onSelect`, handed the section's
/// index).
///
/// **The binding owns**: which section is pinned (the headers' own rule,
/// `SectionHeaderPillButton.pinnedSection`); minting the item
/// (`SectionBarItem`: one identifier per title and count, so it morphs);
/// placing it ONCE per turn, and never during a push or a pop — items set
/// mid-transition land unanimated at its end (`bar-items-during-push`); and
/// keeping the screen's other items.
///
/// **Placement is the screen's**:
/// - `.leading`: after the back chevron (`leftItemsSupplementBackButton`) and
///   the screen's items that come first (`leadingPrefix`, the inbox's bell),
///   or first when there are none, then the screen's other leading items
///   (`leadingItems`);
/// - `.trailing`: before the screen's own trailing items (`trailingItems`),
///   through `setOwnTrailingBarItems` — a bar toast that holds the trailing
///   group gives them back with the section item in place.
///
/// A `separator` (a fixed space) keeps the section item in its own glass
/// bubble beside the screen's items: adjacent items otherwise share one.
///
/// A screen that writes its own items on the bound side at moments of its own
/// choosing — inside a push, so they ride it (the profile) — hands them over
/// and places at once (`placeNow(animated:)`); the section item still comes
/// and goes on the binding's own rules.
///
/// A screen never edits the item arrays itself while bound: it sets
/// `leadingPrefix` / `leadingItems` / `trailingItems` here instead — or, while
/// it shows a bar of another kind (the inbox's search), suspends the binding
/// (`isSuspended`), which places again when it resumes.
@MainActor
public final class PinnedSectionBarBinding {
    /// One section, as the screen describes it.
    public struct Section: Equatable, Sendable {
        public let id: String
        public let title: String
        /// Shown after the title, "Title · n"; zero for none.
        public let count: Int

        public init(id: String, title: String, count: Int = 0) {
            self.id = id
            self.title = title
            self.count = count
        }
    }

    public enum Placement: Sendable {
        case leading
        case trailing
    }

    public let placement: Placement
    /// The section pinned now, and where it is in the list — nil while the
    /// list rests at its top (the first header is a title in the flow).
    public private(set) var pinned: (index: Int, section: Section)?
    /// The item naming it while it is pinned.
    public private(set) var item: UIBarButtonItem?
    /// The screen's own items on the same side, kept around the section item:
    /// `leadingPrefix` before it, `leadingItems` after it.
    public var leadingPrefix: [UIBarButtonItem] = [] { didSet { schedulePlacement() } }
    public var leadingItems: [UIBarButtonItem] = [] { didSet { schedulePlacement() } }
    public var trailingItems: [UIBarButtonItem] = [] { didSet { schedulePlacement() } }
    /// A tap on the item: scroll section `index`'s header under the bar.
    public var onSelect: ((Int) -> Void)?
    /// While true the binding keeps its state and writes nothing to the bar:
    /// the screen shows a bar of another kind. Resuming places at once.
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue, !isSuspended else { return }
            schedulePlacement()
        }
    }

    private weak var viewController: UIViewController?
    private let scope: String
    private let countNoun: String
    /// Between the screen's items and the section item, when both show.
    private let separator: UIBarButtonItem?
    private var placementScheduled = false

    /// - Parameters:
    ///   - scope: the items' identifier prefix, one per screen.
    ///   - countNoun: what a count counts, for VoiceOver ("new", "unread").
    ///   - separator: a fixed space between the screen's items and the
    ///     section item, so each keeps its own glass; nil for none.
    public init(
        viewController: UIViewController, placement: Placement, scope: String, countNoun: String = "new",
        separator: UIBarButtonItem? = nil
    ) {
        self.viewController = viewController
        self.placement = placement
        self.scope = scope
        self.countNoun = countNoun
        self.separator = separator
        if placement == .leading { viewController.navigationItem.leftItemsSupplementBackButton = true }
    }

    /// Re-reads the list. `sectionTops` are the sections' natural top edges
    /// in content coordinates, in order; `pinLine` is `contentOffset.y +
    /// adjustedContentInset.top`. Cheap: the bar changes only when the
    /// pinned section (or its count) does.
    public func update(sections: [Section], sectionTops: [CGFloat], pinLine: CGFloat) {
        let index = SectionHeaderPillButton.pinnedSection(sectionTops: sectionTops, pinLine: pinLine)
            .flatMap { sections.indices.contains($0) ? $0 : nil }
        show(pinned: index.map { ($0, sections[$0]) })
    }

    /// The pinned section, as a list that works it out itself says it — nil
    /// back at the top. The same bar rules as `update`: a new item only for
    /// a new section or count, placed once per turn, never mid-transition.
    public func show(pinned next: (index: Int, section: Section)?) {
        guard next?.section != pinned?.section || next?.index != pinned?.index else { return }
        let sectionChanged = next?.section != pinned?.section
        pinned = next
        guard sectionChanged else { return }
        item = next.map { _, section in
            SectionBarItem.make(
                title: section.title, count: section.count, countNoun: countNoun, scope: scope
            ) { [weak self] in
                // The section's place NOW: the same section can move.
                guard let self, let pinned else { return }
                onSelect?(pinned.index)
            }
        }
        schedulePlacement()
    }

    /// `update` for a scroll view: the pin line read off it.
    public func update(sections: [Section], sectionTops: [CGFloat], in scrollView: UIScrollView) {
        update(
            sections: sections, sectionTops: sectionTops,
            pinLine: scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        )
    }

    // MARK: - Placement

    /// The items the bound side shows now.
    public var placedItems: [UIBarButtonItem] {
        switch placement {
        case .leading: placedLeading(leadingPrefix)
        case .trailing: placedTrailing(trailingItems)
        }
    }

    /// The trailing group with `own` as the screen's items: what a screen
    /// that places at once compares with what the bar shows.
    public func placedTrailing(_ own: [UIBarButtonItem]) -> [UIBarButtonItem] {
        guard placement == .trailing, let item else { return own }
        return own + (own.isEmpty ? [] : [separator].compactMap { $0 }) + [item]
    }

    private func placedLeading(_ prefix: [UIBarButtonItem]) -> [UIBarButtonItem] {
        guard let item else { return prefix + leadingItems }
        return prefix + (prefix.isEmpty ? [] : [separator].compactMap { $0 }) + [item] + leadingItems
    }

    /// ONCE, on the next turn: a scroll can publish twice in one turn, and a
    /// second `set…BarButtonItems` cuts the first one's animation short.
    private func schedulePlacement() {
        guard let viewController, !isSuspended else { return }
        guard viewController.viewIfLoaded?.window != nil else {
            place(animated: false)
            return
        }
        guard !placementScheduled else { return }
        placementScheduled = true
        DispatchQueue.main.async { [weak self] in self?.placeAfterTransition() }
    }

    /// ⚠️ NOT DURING A PUSH OR A POP (#756): a placement due then waits for
    /// the transition's end, then animates.
    private func placeAfterTransition() {
        if let coordinator = viewController?.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               DispatchQueue.main.async { self?.placeAfterTransition() }
           }) {
            return
        }
        placementScheduled = false
        place(animated: true)
    }

    private func place(animated: Bool) {
        guard let viewController, !isSuspended else { return }
        let items = placedItems
        switch placement {
        case .leading:
            // An identical group is not handed back: re-setting the same
            // items rebuilt the glass mid-transition (the profile's guard).
            guard !(viewController.navigationItem.leftBarButtonItems ?? []).elementsEqual(items, by: ===) else { return }
            viewController.navigationItem.setLeftBarButtonItems(items, animated: animated)
        case .trailing:
            // The same rule on this side: an identical group is not handed
            // back (the profile's `appliedBarItems`, now here).
            guard !viewController.ownTrailingBarItems.elementsEqual(items, by: ===) else { return }
            // ⚠️ Through the toasts' door: while a toast holds the trailing
            // group, these are what come back when it leaves.
            viewController.setOwnTrailingBarItems(items, animated: animated)
        }
    }

    /// Places now, unanimated, skipping the turn and the transition wait: for
    /// a screen rebuilding its whole bar in one go (the inbox handing its bar
    /// back from search, inside the bar's own crossfade).
    public func placeNow(animated: Bool = false) {
        placementScheduled = false
        place(animated: animated)
    }

    #if DEBUG
    /// `placeNow`, for tests.
    public func debugPlaceNow() { placeNow() }
    #endif
}

/// The pinned-section rule for a list that names its section to a host
/// rather than to a bar of its own (the inbox's pages, each telling the
/// screen in front): which section's header has gone under the pin line —
/// the headers' own rule (`SectionHeaderPillButton.pinnedSection`) — told
/// only when it changes, since a scroll asks every frame. What the host then
/// shows through `PinnedSectionBarBinding.show(pinned:)` (#1573).
@MainActor
public final class PinnedSectionTracker<Value: Equatable> {
    /// What is pinned now; nil at the top, or over an unnamed section.
    public private(set) var pinned: Value?
    /// Where `pinned` sits in the list — what a tap scrolls to.
    public private(set) var index: Int?
    /// `pinned` changed.
    public var onChange: ((Value?) -> Void)?

    public init() {}

    /// Re-reads the list: `sectionTops` in content coordinates, `pinLine`
    /// `contentOffset.y + adjustedContentInset.top`; `value` names section
    /// `i`, or answers nil for one the bar does not name.
    public func update(sectionTops: [CGFloat], pinLine: CGFloat, value: (Int) -> Value?) {
        let found = SectionHeaderPillButton.pinnedSection(sectionTops: sectionTops, pinLine: pinLine)
            .flatMap { index in value(index).map { (index, $0) } }
        index = found?.0
        let next = found?.1
        guard next != pinned else { return }
        pinned = next
        onChange?(next)
    }

    /// `update` for a table: its sections' tops and pin line read off it.
    public func update(in tableView: UITableView, value: (Int) -> Value?) {
        update(
            sectionTops: (0..<tableView.numberOfSections).map { tableView.rect(forSection: $0).minY },
            pinLine: tableView.contentOffset.y + tableView.adjustedContentInset.top,
            value: value
        )
    }
}
