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
    /// Fired whenever the chrome changes — which today means a badge count
    /// landing.
    var onChromeChange: ((InboxSurfaceChrome) -> Void)? { get set }

    /// The page became the active one (settled swipe, header tap, or the
    /// initial category on appear). Must be idempotent and cheap — it fires
    /// again every time the user pages back, so surfaces that load eagerly
    /// simply no-op here and lazy ones guard their first load.
    func surfaceDidBecomeActive()

    /// The SCREEN is going away — another root tab, a pushed thread, a pop.
    ///
    /// This is where a tab's badge retires, and it is deliberately not the
    /// counterpart of `surfaceDidBecomeActive`: paging between tabs fires
    /// neither, because the badges are read against each other and a count that
    /// vanishes when you switch to compare it is a count you cannot use. It
    /// reaches EVERY surface, not just the one that was forward.
    func surfaceWillResignActive()
}

extension InboxSurface {
    /// Most surfaces have nothing to settle on the way out.
    func surfaceWillResignActive() {}
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
