import DesignSystem
import UIKit

/// The section a list has scrolled into — what the inbox names in its bar,
/// after the bell (#1301), instead of a capsule pinned under the bar. Each
/// list works it out with the one rule (`PinnedSectionTracker`, #1573).
struct InboxPinnedSection: Equatable {
    var section: InboxListSection
    /// Its unread messages, as its header counts them (#1210).
    var count: Int

    var title: String { section.title }
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
