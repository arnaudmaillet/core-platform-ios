import CoreNavigation
import UIKit

/// Everything a surface asks the inbox container to render on its behalf.
///
/// Bar items live here rather than on the surface's own `navigationItem`
/// because a paged child has no navigation bar of its own — the container's is
/// the only one on screen. Publishing them as data (instead of letting pages
/// reach for shared chrome) keeps the container the single writer of the
/// navigation bar, which is what makes "who owns the header" answerable.
struct InboxSurfaceChrome {
    /// Navigation bar title while this surface is active, which DISPLACES the
    /// tab capsule for as long as it is non-nil — the two share one slot.
    ///
    /// `nil` is the resting state and the tabs hold the slot. Editing is the
    /// only caller: it puts the selection count there, which is where a count
    /// belongs (hanging it off the action — "Delete (2)" — crowds the bar
    /// enough to truncate on a 402pt screen), and paging is frozen while it
    /// does, so the tabs are giving up nothing anyone could use.
    var title: String?
    /// Leading bar item while this surface is active, OVERRIDING the container's
    /// Compose; `nil` leaves Compose in place, which is the resting state.
    ///
    /// ⚠️ **Editing only.** The resting bar is two fixed glyphs — Compose and
    /// Search — on every tab, and nothing a page publishes may change that.
    /// What a page offers goes in `contextMenu`.
    var leadingBarItem: UIBarButtonItem?
    /// Trailing bar items while active, in `rightBarButtonItems` order
    /// (first = outermost).
    ///
    /// ⚠️ **Editing only, same rule as `leadingBarItem`.** These are the batch
    /// actions a multi-selection needs, and editing is a MODE — paging is
    /// frozen, the capsule has stepped aside for the selection count, and the
    /// bar's width is nobody's business but the mode's. In the resting state
    /// this must be empty.
    ///
    /// **Why the rule exists, in numbers.** The tab capsule is the navigation
    /// bar's title view, so it gets exactly what the side items leave it. When
    /// pages published their own words here the slot measured 252pt with no
    /// item, 239.7 with "Edit", 228.7 with "Clear" and ~190 with "Clear All" —
    /// so the tabs were re-laid out, and truncated, according to which page you
    /// happened to be on. Fixed glyphs make the slot one number.
    var trailingBarItems: [UIBarButtonItem] = []
    /// Count stamped beside this surface's segment title; 0 hides the badge.
    /// Honoured whether or not the surface is active — that is the point of a
    /// badge.
    var badgeCount: Int = 0
    /// Suspends paging while true (a half-made multi-selection has no sensible
    /// outcome if the page slides away under it).
    var locksPaging = false
    /// What a long press on THIS surface's tab offers — "Clear All Requests" on
    /// Requests, "Mark All as Read" and "Select Messages" on All.
    ///
    /// This is where a page's actions live now. It reaches the viewer without
    /// touching the navigation bar at all, so it cannot change the header's
    /// geometry, and it works from any tab: the menu hangs off the segment, not
    /// off whichever page happens to be showing.
    var contextMenu: UIMenu?
}

/// The contract between the inbox container and one of its paged surfaces.
///
/// This is deliberately the *whole* coupling: the container knows a page's
/// category, its scroll view, the chrome it wants, and when to wake it. It
/// knows nothing about a page's data, phases, or cells — so a fourth surface
/// is one conformer plus one `MessagesCategory` case, with no container edits
/// beyond the page list.
@MainActor
protocol InboxSurface: UIViewController {
    var category: MessagesCategory { get }

    /// The current chrome. Read when the surface becomes active, and again on
    /// every `onChromeChange`.
    var chrome: InboxSurfaceChrome { get }
    /// Fired whenever the chrome changes — entering editing, a badge count
    /// landing, a selection emptying.
    var onChromeChange: ((InboxSurfaceChrome) -> Void)? { get set }

    /// The page became the active one (settled swipe, header tap, or the
    /// initial category on appear). Must be idempotent and cheap — it fires
    /// again every time the user pages back, so surfaces that load eagerly
    /// simply no-op here and lazy ones guard their first load.
    func surfaceDidBecomeActive()
}

extension MessagesCategory {
    /// The header segment's title.
    var title: String {
        switch self {
        case .all: "All"
        case .requests: "Requests"
        case .suggestions: "Suggestions"
        }
    }
}
