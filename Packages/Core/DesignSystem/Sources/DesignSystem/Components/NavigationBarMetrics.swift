import UIKit

// ⚠️ THE BAR DISSOLVE HELPER LIVED HERE: a cross-dissolve of the whole bar,
// the inbox's and the relationships' way into a hand-made search field.
// Both moved to `UISearchController` (#1679, the owner 2026-10-24: R3, UIKit
// animates bars) and the dissolve went with them — the bar contract's guard
// (`BarContractGuardTests.noNewHandMadeBarMorph`) keeps it gone.

/// The size of the glass pill UIKit draws behind a bar button item.
///
/// ⚠️ **44pt, and it is NOT the button's own height.** A bar item nests like
/// this, measured on iPhone 17 Pro / iOS 26.5 by walking up from a "Cancel"
/// label (the inbox's old search audit):
///
///     _UIModernBarButton  h=32.3
///     _UIButtonBarButton  h=36.0   ← the touch target
///     PlatterItemView     h=36.0
///     PlatterGlassView    h=44.0   ← THE PILL THE VIEWER SEES
///     PlatterView         h=44.0
///
/// A custom title view that wants to look like a sibling of the bar's buttons
/// has to match the PILL, not the button. Sizing a search field to 36 was
/// measured against `_UIButtonBarButton` and is why the field sat visibly
/// shorter than the Cancel pill beside it while sharing its centre line
/// exactly — an equal-centres check passes on two pills of different heights,
/// which is how it survived.
public enum NavigationBarMetrics {
    /// The height of a bar button item's glass platter.
    public static let itemPlatterHeight: CGFloat = 44
}
