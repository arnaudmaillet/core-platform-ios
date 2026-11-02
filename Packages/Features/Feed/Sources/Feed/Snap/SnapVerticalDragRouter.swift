import Foundation

/// Who owns a downward drag beginning on the full-screen feed (#2056, #2057,
/// the owner 2026-11-02): the PAGER, which pages back to the previous post,
/// or the screen's DISMISSAL (the hero grab, the slide, the card close).
///
/// ⚠️ ONE ANSWER, ASKED BY BOTH SIDES. The pager's per-touch gate
/// (`SnapFeedCollectionView`) and the dismissal drivers' vertical gate
/// (`zoomVerticalDismissalPermitted`) used to be written as each other's
/// mirror — forward-only (#114): the pager declined every downward drag,
/// the dismissal took every one. Now both ask this, so exactly one of them
/// claims a drag: never both, never neither.
///
/// Decided as the drag begins, from where the feed rests — the rule the
/// owner set for the comment tiers' edges (#2042): a fling that reaches
/// the first post mid-drag stops there; dismissing takes a new drag.
///
/// Pure, for tests (`SnapVerticalDragRouterTests`).
enum SnapVerticalDragRouter {
    enum DownwardOwner: Equatable {
        /// The previous post comes in.
        case pager
        /// The screen closes (or nothing, on a feed with no dismissal).
        case dismissal
    }

    struct Situation: Equatable {
        /// The page the feed rests on.
        var settledIndex: Int
        /// Whether it rests exactly on it — not mid-scroll, not bouncing.
        var isAtRestOnPage: Bool
        /// The side list is open (#1425): the pager pages both ways and the
        /// dismissal stands aside, whatever the page.
        var sideListOpen: Bool
        /// Whether the page on screen pages back through the pager: a media
        /// page. A text page, or a page whose comments hold the scroll, has
        /// the pager disabled; its downward drag stays the close until the
        /// direction-aware drive (#2058) pages it back.
        var pagerPagesHere: Bool
    }

    static func downwardOwner(_ situation: Situation) -> DownwardOwner {
        if situation.sideListOpen { return .pager }
        // Between two pages, a drag continues the scroll.
        if !situation.isAtRestOnPage { return .pager }
        // The first post keeps the downward dismiss; any later post pages back.
        if situation.settledIndex > 0, situation.pagerPagesHere { return .pager }
        return .dismissal
    }
}
