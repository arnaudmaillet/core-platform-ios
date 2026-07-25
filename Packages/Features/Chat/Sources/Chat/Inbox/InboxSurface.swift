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
    /// Leading bar item while this surface is active; `nil` for none.
    var leadingBarItem: UIBarButtonItem?
    /// Trailing bar items while active, in `rightBarButtonItems` order
    /// (first = outermost). Empty yields the container's compose item, which
    /// belongs to the inbox as a whole rather than to any page. Editing
    /// surfaces publish their batch actions here, which is why this is a list:
    /// every tab's edit mode offers two.
    var trailingBarItems: [UIBarButtonItem] = []
    /// Count stamped beside this surface's segment title; 0 hides the badge.
    /// Honoured whether or not the surface is active — that is the point of a
    /// badge.
    var badgeCount: Int = 0
    /// Suspends paging while true (a half-made multi-selection has no sensible
    /// outcome if the page slides away under it).
    var locksPaging = false
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
