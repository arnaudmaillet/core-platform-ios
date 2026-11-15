import UIKit

/// Every `UISwitch` in the app turns the primary when on (#2435).
///
/// ⚠️ **A SWITCH IGNORES THE WINDOW'S TINT.** `SceneDelegate` sets
/// `window.tintColor = Palette.tint`, and every other system control follows
/// it — but a `UISwitch` takes its on track from `onTintColor` alone, and
/// stays `systemGreen` while that is unset. Nothing in the app set it, so
/// every switch was green. One appearance rule at launch reaches them all,
/// the ones added later included, as `ScrollIndicatorStyle` does for the
/// scroll bars.
///
/// It is `Palette.tint` itself, the dynamic colour: Increased Contrast takes
/// the primary's deeper values. The off track and the thumb stay the
/// system's. A screen that wants another colour sets `onTintColor` on its
/// own switch; an instance value outranks the appearance default.
public enum SwitchStyle {
    /// Call once, before any view is built (`SceneDelegate`, beside
    /// `ScrollIndicatorStyle.hideAppWide()`): an appearance default only
    /// reaches views made after it is set.
    public static func tintAppWide() {
        UISwitch.appearance().onTintColor = Palette.tint
    }
}
