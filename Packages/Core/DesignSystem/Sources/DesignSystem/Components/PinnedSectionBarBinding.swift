import UIKit

/// ⚠️ ONE CONTRACT BINDING A SCREEN'S SECTIONS TO A BAR ITEM (#1573, the owner
/// 2026-10-22): the section the list has scrolled into, named in the bar —
/// "New · 3", "Yesterday" — and a tap on it scrolls back to that section's
/// header. For You's pushed lists (#1378), the Messages inbox (#1301) and
/// the profile each wired this by hand; a screen now only describes its
/// sections and says where the item goes.
///
/// **The screen provides**: its sections (identifier, title, optional count)
/// and their tops in its scroll view, at every scroll (`update`); and what a
/// tap does (`onSelect`, handed the section's index).
///
/// **The binding owns**: which section is pinned (the headers' own rule,
/// `SectionHeaderPillButton.pinnedSection`); minting the item
/// (`SectionBarItem`: one identifier per title and count, so it morphs);
/// placing it ONCE per turn, and never during a push or a pop — items set
/// mid-transition land unanimated at its end (`bar-items-during-push`); and
/// keeping the screen's other items.
///
/// **Placement is the screen's**:
/// - `.leading`: after the back chevron (`leftItemsSupplementBackButton`), or
///   first when there is none, then the screen's own leading items
///   (`leadingItems`);
/// - `.trailing`: before the screen's own trailing items (`trailingItems`),
///   through `setOwnTrailingBarItems` — a bar toast that holds the trailing
///   group gives them back with the section item in place.
///
/// A screen never edits the item arrays itself while bound: it sets
/// `leadingItems` / `trailingItems` here instead.
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
    /// The screen's own items on the same side, kept around the section item.
    public var leadingItems: [UIBarButtonItem] = [] { didSet { schedulePlacement() } }
    public var trailingItems: [UIBarButtonItem] = [] { didSet { schedulePlacement() } }
    /// A tap on the item: scroll section `index`'s header under the bar.
    public var onSelect: ((Int) -> Void)?

    private weak var viewController: UIViewController?
    private let scope: String
    private let countNoun: String
    private var placementScheduled = false

    /// - Parameters:
    ///   - scope: the items' identifier prefix, one per screen.
    ///   - countNoun: what a count counts, for VoiceOver ("new", "unread").
    public init(
        viewController: UIViewController, placement: Placement, scope: String, countNoun: String = "new"
    ) {
        self.viewController = viewController
        self.placement = placement
        self.scope = scope
        self.countNoun = countNoun
        if placement == .leading { viewController.navigationItem.leftItemsSupplementBackButton = true }
    }

    /// Re-reads the list. `sectionTops` are the sections' natural top edges
    /// in content coordinates, in order; `pinLine` is `contentOffset.y +
    /// adjustedContentInset.top`. Cheap: the bar changes only when the
    /// pinned section (or its count) does.
    public func update(sections: [Section], sectionTops: [CGFloat], pinLine: CGFloat) {
        let index = SectionHeaderPillButton.pinnedSection(sectionTops: sectionTops, pinLine: pinLine)
            .flatMap { sections.indices.contains($0) ? $0 : nil }
        let next = index.map { ($0, sections[$0]) }
        guard next?.1 != pinned?.section || next?.0 != pinned?.index else { return }
        let sectionChanged = next?.1 != pinned?.section
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
        case .leading: (item.map { [$0] } ?? []) + leadingItems
        case .trailing: trailingItems + (item.map { [$0] } ?? [])
        }
    }

    /// ONCE, on the next turn: a scroll can publish twice in one turn, and a
    /// second `set…BarButtonItems` cuts the first one's animation short.
    private func schedulePlacement() {
        guard let viewController else { return }
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
        guard let viewController else { return }
        let items = placedItems
        switch placement {
        case .leading:
            viewController.navigationItem.setLeftBarButtonItems(items, animated: animated)
        case .trailing:
            // ⚠️ Through the toasts' door: while a toast holds the trailing
            // group, these are what come back when it leaves.
            viewController.setOwnTrailingBarItems(items, animated: animated)
        }
    }

    #if DEBUG
    /// Places now, skipping the turn and the transition wait. Tests.
    public func debugPlaceNow() {
        placementScheduled = false
        place(animated: false)
    }
    #endif
}
