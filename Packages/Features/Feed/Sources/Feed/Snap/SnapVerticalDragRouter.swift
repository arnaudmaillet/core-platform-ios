import Foundation

/// Who owns a downward drag beginning on the full-screen feed (#2056, #2057,
/// the owner 2026-11-02): the PAGER, which pages back to the previous post,
/// or the screen's DISMISSAL (the hero grab, the slide, the card close).
///
/// The pager is the native one on a media page, and the hand-moved drive
/// (`SnapPageDrive`) where the comments hold the page: a text page, an open
/// panel. There the composer and the header band start the drive (#2058),
/// and on a text page a stream its room holds whole and the pull past a
/// scrolling stream's top (#2298) ask this too.
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
        /// The previous post comes in, through the pager or the drive.
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
        /// the pager disabled.
        var pagerPagesHere: Bool
        /// Whether the hand-moved drive pages it instead: the comments are
        /// engaged — a text page, or an open panel (#2058).
        var drivePagesHere: Bool
    }

    static func downwardOwner(_ situation: Situation) -> DownwardOwner {
        if situation.sideListOpen { return .pager }
        // Between two pages, a drag continues the scroll.
        if !situation.isAtRestOnPage { return .pager }
        // The first post keeps the downward dismiss; any later post pages back.
        if situation.settledIndex > 0, situation.pagerPagesHere || situation.drivePagesHere { return .pager }
        return .dismissal
    }
}
