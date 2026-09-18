import UIKit

/// How a screen with two strips in the stack's bottom toolbar — a leading one
/// at its own width, a trailing selector taking the rest — reads the bar.
///
/// ⚠️ **SHARED BY THE EDITOR AND THE CAMERA, SO THE TWO BARS ARE ONE RULE.**
/// These were the editor's private helpers; the camera's toolbar is the same
/// two-strip bar (asked for in those words: "le même système qu'on a fait sur
/// l'écran d'édition des médias"), so they moved here rather than being
/// copied. The arithmetic stays in `EditorSelectorLayout` and
/// `ToolbarGeometry`; each screen keeps its own constraints and hand-overs.
@MainActor
enum BottomBarShare {
    /// The first ancestor wider than `view`, in window coordinates — the
    /// platter a bar item sits on.
    static func platter(of view: UIView) -> CGRect? {
        guard let window = view.window else { return nil }
        let own = view.convert(view.bounds, to: nil)
        var node = view.superview
        while let current = node, current !== window {
            let frame = current.convert(current.bounds, to: nil)
            if frame.width > own.width + 0.5 {
                return frame.width < window.bounds.width ? frame : nil
            }
            node = current.superview
        }
        return nil
    }

    /// The width a strip would take on its own.
    ///
    /// ⚠️ **NOT `intrinsicContentSize` ALONE.** `IconActionBar` states one;
    /// `SoundPillView` answers `noIntrinsicMetric` (-1) because its size comes
    /// from its own subviews' constraints, and -1 read as a width gave the
    /// selector the whole bar and the pill nothing.
    static func wantedWidth(of view: UIView) -> CGFloat {
        let stated = view.intrinsicContentSize.width
        guard stated == UIView.noIntrinsicMetric else { return stated }
        return view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
    }

    /// The bar's geometry read from the two strips' platters, or nil while
    /// they are not both on screen and at rest — see
    /// `ToolbarGeometry.measured`.
    ///
    /// ⚠️ **ONLY WHILE BOTH ARE ON SCREEN.** A collapsed item has no platter,
    /// and a geometry read from one would be the collapse measuring itself.
    static func measure(leading: UIView, trailing: UIView) -> ToolbarGeometry? {
        guard let window = leading.window, trailing.window === window,
              let leadingPlatter = platter(of: leading),
              let trailingPlatter = platter(of: trailing)
        else { return nil }
        return ToolbarGeometry.measured(
            leading: leading.convert(leading.bounds, to: nil),
            leadingPlatter: leadingPlatter,
            trailing: trailing.convert(trailing.bounds, to: nil),
            trailingPlatter: trailingPlatter
        )
    }
}
