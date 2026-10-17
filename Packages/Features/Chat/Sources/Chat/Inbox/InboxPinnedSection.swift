import DesignSystem
import UIKit

/// The section a list has scrolled into — what the inbox names in its bar,
/// after the bell (#1301), instead of a capsule pinned under the bar.
struct InboxPinnedSection: Equatable {
    var section: InboxListSection
    /// Its unread messages, as its header counts them (#1210).
    var count: Int

    var title: String { section.title }
}

/// Works out which section of a sectioned inbox list is stuck at the pin line,
/// and says so only when that changes: a scroll asks every frame, and the bar
/// must not be rewritten on every one of them.
///
/// Shared by the two sectioned lists (Chats, Requests). The rule is the
/// headers' own (`SectionHeaderPillButton.pinnedSection`), so the bar names a
/// section exactly while that section's header has left the list.
@MainActor
final class InboxPinnedSectionTracker {
    private(set) var pinned: InboxPinnedSection?
    /// Where `pinned` sits in the table — what a tap on the bar item scrolls to.
    private(set) var index: Int?
    var onChange: ((InboxPinnedSection?) -> Void)?

    /// Re-reads the list. `headedSection` answers nil for an unheaded list
    /// (one with no arrivals), which names nothing.
    func update(
        in tableView: UITableView,
        headedSection: (Int) -> InboxListSection?,
        count: (InboxListSection) -> Int
    ) {
        let pinLine = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let tops = (0..<tableView.numberOfSections).map { tableView.rect(forSection: $0).minY }
        let found = SectionHeaderPillButton.pinnedSection(sectionTops: tops, pinLine: pinLine)
            .flatMap { index in headedSection(index).map { (index, $0) } }
        index = found?.0
        let next = found.map { InboxPinnedSection(section: $0.1, count: count($0.1)) }
        guard next != pinned else { return }
        pinned = next
        onChange?(next)
    }
}

extension UITableView {
    /// Puts a section's first row on the PIN LINE, under the bar — what
    /// tapping that section's name means: "show me this part".
    ///
    /// ⚠️ NOT `scrollToRow(at:.top)`. A plain table keeps its pinned header's
    /// box in front of the row it scrolls to, which was right while the
    /// capsule was drawn in that box. The inbox names the stuck section in its
    /// bar instead and the pinned header hides (#1301), so `.top` landed the
    /// row under an empty band as tall as the header — measured at 55pt when
    /// this was first tried (#179). The offset is set by hand: the row's own
    /// top on the line, its hidden header stuck over it as it is mid-scroll.
    ///
    /// Clamped for a list too short to scroll — an offset cannot invent
    /// content, so a list that already fits on screen stays where it is.
    func scrollFirstRow(ofSection section: Int, animated: Bool = true) {
        guard numberOfSections > section, numberOfRows(inSection: section) > 0 else { return }
        layoutIfNeeded()
        let row = rectForRow(at: IndexPath(row: 0, section: section))
        let inset = adjustedContentInset
        let furthest = contentSize.height + inset.bottom - bounds.height
        let target = min(row.minY - inset.top, furthest)
        setContentOffset(CGPoint(x: 0, y: max(-inset.top, target)), animated: animated)
    }
}
