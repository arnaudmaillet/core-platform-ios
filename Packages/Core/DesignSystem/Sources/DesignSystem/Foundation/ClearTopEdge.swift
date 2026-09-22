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
    /// was. (The Maps tab keeps a light gradient under its status bar; that
    /// is MapKit's own edge effect, private and unswitchable, not this app's.)
    ///
    /// ## ⚠️ A pager needs it as well as its pages
    ///
    /// A horizontal pager's own scroll view spans the header too, and draws its
    /// own edge effect over the pages. With only the pages hidden, the pager's
    /// band still shows (measured on For You and the inbox when the style was
    /// the thing being set). `HorizontalPagerView`, `ForYouPagerView` and
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
}
