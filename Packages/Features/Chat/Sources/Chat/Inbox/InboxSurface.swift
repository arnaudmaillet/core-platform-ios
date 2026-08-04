import CoreNavigation
import UIKit

/// Everything a surface asks the inbox container to render on its behalf.
///
/// It is deliberately small, and it got smaller: pages used to publish bar
/// items too, and a paged child has no navigation bar of its own, so the
/// container wrote them on its behalf. That is gone. The navigation bar's two
/// glyphs belong to the inbox as a whole and never change, which is what keeps
/// the tab capsule between them a fixed width — so what a PAGE contributes is
/// only what rides its own tab.
struct InboxSurfaceChrome {
    /// Count stamped beside this surface's segment title; 0 hides the badge.
    /// Honoured whether or not the surface is active — that is the point of a
    /// badge.
    var badgeCount: Int = 0
    /// What a long press on THIS surface's tab offers — "Clear All Requests" on
    /// Requests, "Mark All as Read" on All, nothing on Suggestions.
    ///
    /// This is where a page's actions live. It reaches the viewer without
    /// touching the navigation bar at all, so it cannot change the header's
    /// geometry, and it works from any tab: the menu hangs off the segment, not
    /// off whichever page happens to be showing. `nil` means the page has
    /// nothing to offer right now, and no menu is better than an empty one.
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
    /// Fired whenever the chrome changes — a badge count landing, or a menu
    /// gaining or losing its last action.
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
