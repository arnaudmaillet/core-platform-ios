import UIKit

public extension UIScrollView {
    /// Asks for the progressive fade under the header that sits over this
    /// scroll view's top edge — `UIScrollEdgeEffect.Style.soft` — instead of
    /// leaving the choice to `.automatic`.
    ///
    /// ## ⚠️ iOS 27 changed what `.automatic` draws under a navigation bar
    ///
    /// Measured on the simulator, one build, the same screens: on iOS 26.5
    /// (iPhone 17 Pro Max) the header over scrolled content is a progressive
    /// blur that fades into it. On iOS 27 (iPhone 18 Pro), with the style left
    /// at `.automatic`, For You, the Messages inbox, the relationship lists, a
    /// pushed post, a conversation and the new-post screen all showed a flat
    /// band with a HARD cutoff and a hairline under the bar — the `.hard` look.
    /// `.soft`, set explicitly, brings the progressive blur back on iOS 27. It is
    /// the native, public style: nothing here draws a blur of its own, and
    /// nothing reaches for private API. (iOS 27's soft fade is a little heavier
    /// than iOS 26's; that is the system's, not ours to tune.)
    ///
    /// On iOS 26 the call is a no-op in effect — `.automatic` already resolves
    /// to the soft fade there. Checked on 26.5, before and after, on For You,
    /// the inbox, a conversation, the relationship lists, a post and the
    /// new-post screen: nothing the call changed on any of them.
    ///
    /// ## ⚠️ A pager needs it as well as its pages
    ///
    /// A horizontal pager's own scroll view spans the header too, and draws its
    /// own edge effect over the pages. With only the pages set to `.soft`, For
    /// You and the inbox still cut the header off at a hard line with a hairline
    /// on iOS 27. `HorizontalPagerView`, `ForYouPagerView` and
    /// `ProfileGalleryPagerView` each call this on their paging scroll view.
    ///
    /// ## Why one call per scroll view, not one app-wide default
    ///
    /// UIKit has no global or appearance-level switch for it. `topEdgeEffect` is
    /// a read-only property returning an object, and `style` lives on that
    /// object — there is no setter on `UIScrollView` for an appearance proxy to
    /// record, which is the one thing that lets `ScrollIndicatorStyle` get away
    /// with a single default. So each screen's scrolling content calls this
    /// where it is configured, and a NEW list under a header must too: one that
    /// does not gets the hard band on iOS 27 and looks fine on iOS 26.
    ///
    /// Only the TOP edge. The bottom edge — above the tab bar, a toolbar, a
    /// composer — stays `.automatic`; nobody has asked for it to change.
    ///
    /// ## ⚠️ Where NOT to call it
    ///
    /// - **Edge effects hidden on purpose**: the snap feed's collection view and
    ///   its shortcut rail (full-bleed media to the bar; a rail that owns its
    ///   `layer.mask`, which a system effect silently evicts) and the media
    ///   editor's canvas (full-bleed under both bars). A style set there would
    ///   not un-hide anything, but it would read as intent to show one.
    /// - **The media picker's album and its pager.** It never had a fade under
    ///   its bar — crisp on iOS 26.5 and on iOS 27 alike, so there is no hard
    ///   line to remove — and `.soft` lays a heavy blur over its top rows on
    ///   iOS 27. It keeps `.automatic`; `MediaPickerViewController` says why.
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
    func prefersSoftTopEdge() {
        topEdgeEffect.style = .soft
    }
}
