import UIKit

public extension UIScrollView {
    /// Turns off the system's edge effect under the header that sits over this
    /// scroll view's top edge — `topEdgeEffect.isHidden = true` — so the rows
    /// run up under the bar's pills with nothing drawn between them.
    ///
    /// ## Why hidden, and not a style
    ///
    /// The navigation bar on iOS 26 and 27 draws no background of its own: its
    /// items float as glass pills, and whatever blur the viewer sees under a
    /// header is `UIScrollEdgeEffect`, drawn by the SCROLL VIEW beneath it.
    /// Its two styles are the bar's height plus a fade (`.soft`, what PR #178
    /// asked for) or a flat band with a hairline (`.hard`). The decision
    /// (2026-09-22, after both were tried and filmed) is that no header wears
    /// any material at all: the content shows through and the pills are the
    /// only chrome. Hidden is the same on both systems, which a style never
    /// was. (The Explore tab's map keeps a light blur under its status bar;
    /// that is MapKit's own edge effect, private and unswitchable. Since
    /// 2026-10-01 other screens wear the same one, on purpose, and since
    /// 2026-10-02 every screen does: `StatusBarBlurView` keeps ONE effect
    /// uncleared, on an inert scroll view of its own in the window, which
    /// UIKit draws over the status band alone — the lists still clear theirs.)
    ///
    /// ## ⚠️ A pager needs it as well as its pages
    ///
    /// A horizontal pager's own scroll view spans the header too, and draws its
    /// own edge effect over the pages. With only the pages hidden, the pager's
    /// band still shows (measured on For You and the inbox when the style was
    /// the thing being set). `HorizontalPagerView` and
    /// `ProfileGalleryPagerView` each call this on their paging scroll view.
    ///
    /// ## Why one call per scroll view, not one app-wide default
    ///
    /// UIKit has no global or appearance-level switch for it. `topEdgeEffect` is
    /// a read-only property returning an object, and `isHidden` lives on that
    /// object — there is no setter on `UIScrollView` for an appearance proxy to
    /// record. So each screen's scrolling content calls this where it is
    /// configured, and a NEW list under a header must too: one that does not
    /// gets the system's band back under its bar.
    ///
    /// ## The exceptions: Settings, the notifications drawer, the sound sheet's gallery
    ///
    /// Every Settings screen wears UIKit's soft top edge
    /// (`prefersSoftTopEdge`, asked for on 2026-10-04).
    ///
    /// The notifications list keeps UIKit's soft top-edge blur on purpose
    /// (asked for on 2026-09-28): it is a panel of its own beside the app, not
    /// one of the app's pages, and does not call this. See
    /// `NotificationsViewController`. The grid the sound sheet's "View all"
    /// pushes wears the same soft blur under its title (asked for on
    /// 2026-09-29, lighter than the automatic one it had) — see
    /// `SoundSheetGalleryViewController`. Both state it through
    /// `applyTopEdge(for: .titled)` since #2240, like every titled screen.
    ///
    /// Only the TOP edge. The bottom edge — above the tab bar, a toolbar, a
    /// composer — stays `.automatic`; nobody has asked for it to change.
    ///
    /// ## ⚠️ Where NOT to call it
    ///
    /// - **Scroll views that already hide both edges** for reasons of their own:
    ///   the snap feed's collection view and its shortcut rail, and the media
    ///   editor's canvas. Calling it there would be true and redundant.
    /// - **Anything no header sits over**: horizontal strips, chip rows and
    ///   trays; a grid stacked BELOW its controls rather than under them (the
    ///   sticker picker); a text view that is a field in a form rather than the
    ///   screen's scrolling content (the profile's bio editor, the composers).
    ///
    /// ## ⚠️ Touching the edge effect is not free on a headless runner
    ///
    /// Reading `topEdgeEffect` materialises Liquid Glass machinery. In July an
    /// init-time access in the shortcut rail was measured holding a whole
    /// headless-CI test process ~64s, once per process, which is why that rail
    /// hides its effects on window attach. The snap feed and the media editor
    /// have touched theirs in `viewDidLoad` under test since, with no outlier in
    /// the per-package CI durations — the precedent these calls follow. If a
    /// package's test duration jumps by about a minute, look here first.
    func prefersClearTopEdge() {
        topEdgeEffect.isHidden = true
    }

    /// UIKit's own SOFT top-edge effect: a blur as tall as the header that
    /// fades out below it, so rows read cleanly as they pass under the bar.
    ///
    /// The exception to `prefersClearTopEdge`, asked for on 2026-10-04 for
    /// every Settings screen (a list of text rows under a large title, where
    /// rows meeting the bar's pills with nothing between them read as
    /// clutter). Native, not a hand-built frost: the 2026-09-22 lesson was
    /// that a masked material reads as non-native, UIKit's effect does not.
    ///
    /// ⚠️ AND THE CONTENT STARTS BELOW ITS FADE (#2240): the effect reaches
    /// past the bar, and at rest a plain list's first row sat in it,
    /// softened before anything had scrolled. This call adds to the top
    /// inset what the first content lacks to clear it — see
    /// `SoftTopEdge` / `topFadeClearance`. A horizontal pager carrying the
    /// blur hands that space to the lists it hosts instead
    /// (`HorizontalPagerView`), since its own content does not scroll under
    /// the bar.
    ///
    /// - Parameter keepsContentBelowFade: false only for a scroll view that
    ///   owns its top inset frame by frame (the comments sheet's stream,
    ///   whose shapes anchor a short stream to the composer and re-assert
    ///   their own inset): a clearance topped up under it would be undone and
    ///   re-added on every pass. Such a caller argues the case on
    ///   `TitledHeaderTopEdgeGuardTests.fadeClearanceOptOuts`.
    func prefersSoftTopEdge(keepsContentBelowFade: Bool = true) {
        topEdgeEffect.isHidden = false
        topEdgeEffect.style = .soft
        guard keepsContentBelowFade else { return }
        if let pager = self as? HorizontalPagerScrollView {
            pager.forwardsTopFadeClearance = true
        } else {
            installTopFadeClearance()
        }
    }

    /// ⚠️ THE ONE RULE FOR A SCREEN'S TOP EDGE (#1591, the owner 2026-10-22):
    /// **a header with a TITLE always wears the soft blur over its bar**, the
    /// way Notifications and Settings do — rows read cleanly as they pass
    /// under the title. An untitled header (For You, the inbox, Explore, a
    /// conversation, Search) stays clear, as decided on 2026-09-22.
    ///
    /// It supersedes the exception list above for titled screens: each
    /// screen states what its header IS, and the edge follows. A screen whose
    /// title is set in one view controller and whose list lives in another
    /// (Relationships: the title on the pager's host, the rows in each page)
    /// states it where the list is configured.
    ///
    /// `TitledHeaderTopEdgeGuardTests` fails on a file that sets a title and
    /// clears its top edge without a reason on its list — and, since #2240,
    /// on a file that sets the soft style by hand, which would skip the
    /// clearance that keeps the first row out of the fade.
    func applyTopEdge(for header: HeaderTopEdge) {
        switch header {
        case .titled: prefersSoftTopEdge()
        case .untitled: prefersClearTopEdge()
        }
    }
}

/// What a screen's header shows — what decides its top edge (#1591).
public enum HeaderTopEdge: Sendable {
    /// A title in the bar: the soft blur covers the bar, and the content
    /// rests below its fade (#2240).
    case titled
    /// No title (pills only, or a root whose content is its own header):
    /// clear.
    case untitled
}
