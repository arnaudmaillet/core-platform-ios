import UIKit

/// Device-screen facts shared by every transition that impersonates the
/// screen itself — the pin flight's card and the timeline's slide-back both
/// round their corners to the physical bezel, and must agree on the radius.
public enum ScreenGeometry {
    /// The physical display corner radius behind `view`, or 0 on square
    /// screens (and off-window views).
    ///
    /// Read via KVC from UIKit's undocumented `_displayCornerRadius` (the key
    /// is assembled, and guarded by `responds(to:)` so a future rename
    /// degrades to the fallback instead of throwing). Fallback: any device
    /// with a home indicator has rounded corners (44 is mid-fleet and close
    /// enough for a half-second flight); everything else is square.
    public static func cornerRadius(behind view: UIView) -> CGFloat {
        guard let window = view.window else { return 0 }
        let key = ["_display", "Corner", "Radius"].joined()
        if window.screen.responds(to: NSSelectorFromString(key)),
           let radius = window.screen.value(forKey: key) as? CGFloat, radius > 0 {
            return radius
        }
        return window.safeAreaInsets.bottom > 0 ? 44 : 0
    }
}
