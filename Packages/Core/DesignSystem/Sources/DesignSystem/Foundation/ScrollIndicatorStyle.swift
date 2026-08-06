import UIKit

/// Turns the scroll indicators off for every scroll view in the app.
///
/// ## Why a global default rather than 26 call sites
///
/// The alternative is setting `showsVerticalScrollIndicator` and
/// `showsHorizontalScrollIndicator` at every place a scroll view is built —
/// 26 files when this was written, across every feature. That version is
/// exhaustive on the day it lands and wrong on the next one: a new list added
/// later shows its bars, and nothing catches it. One default at launch covers
/// the scroll views that exist, the ones added later, and the ones UIKit
/// builds internally on our behalf (a list's own scroller, a text view's).
///
/// ## ⚠️ This rides an undocumented capability, and it is tested for that reason
///
/// Neither property is marked `UI_APPEARANCE_SELECTOR`. `UIAppearance` records
/// invocations on the proxy and replays them when a view moves to a window,
/// which works for these two today — verified on iOS 26 for `UIScrollView` and
/// `UICollectionView` before this was written, and pinned by
/// `ScrollIndicatorStyleTests` so that a future release which stops honouring
/// it fails a test instead of quietly putting the bars back.
///
/// The consequence of it being an appearance default rather than a stored
/// value: a scroll view reports the property as `true` until it is *in a
/// window*. That is invisible in practice — an off-screen scroll view draws no
/// indicator to hide — but it is why the test attaches to one, and why reading
/// the flag as a proxy for "will this show bars" is not reliable.
///
/// A screen that genuinely wants its indicators back sets them to `true`
/// itself; an explicit local value wins over the appearance default.
public enum ScrollIndicatorStyle {
    /// Call once, before any view is built. `SceneDelegate` does it at the top
    /// of scene setup — earlier than the first controller, which is what makes
    /// the very first screen obey it too.
    public static func hideAppWide() {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }
}
