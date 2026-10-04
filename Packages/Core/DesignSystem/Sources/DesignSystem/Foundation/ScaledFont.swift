import UIKit

/// Fonts that follow Dynamic Type from a size designed at the default text
/// size (#482).
///
/// `UIFont.systemFont(ofSize: 13)` stays 13 pt whatever the viewer chose in
/// iOS Settings → Display & Text Size. These keep the designed size at the
/// default (Large) setting and scale it with the text style it sits closest
/// to, so a design that needs a weight or a size the text styles don't offer
/// still grows with the viewer's choice.
///
/// ⚠️ PASS THE DESIGNED SIZE, NOT `preferredFont(forTextStyle:).pointSize`.
/// That size is already scaled; feeding it to `UIFontMetrics` scales it a
/// second time (at AX5 a 17 pt body would land near 100 pt).
///
/// A label showing one of these should set
/// `adjustsFontForContentSizeCategory = true` so it re-scales live when the
/// setting changes. `maximumPointSize` caps text living in fixed chrome
/// (a chip, a capsule) where unbounded growth would clip — what iOS does for
/// tab bar titles.
///
/// Text styles at the default size, for picking `relativeTo`: caption2 11,
/// caption1 12, footnote 13, subheadline 15, callout 16, body/headline 17,
/// title3 20, title2 22, title1 28, largeTitle 34.
extension UIFont {
    public static func scaledSystemFont(
        ofSize size: CGFloat,
        weight: Weight = .regular,
        relativeTo style: TextStyle,
        maximumPointSize: CGFloat? = nil,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        scaled(
            .systemFont(ofSize: size, weight: weight),
            relativeTo: style, maximumPointSize: maximumPointSize, compatibleWith: traits
        )
    }

    public static func scaledMonospacedDigitSystemFont(
        ofSize size: CGFloat,
        weight: Weight = .regular,
        relativeTo style: TextStyle,
        maximumPointSize: CGFloat? = nil,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        scaled(
            .monospacedDigitSystemFont(ofSize: size, weight: weight),
            relativeTo: style, maximumPointSize: maximumPointSize, compatibleWith: traits
        )
    }

    /// `font` (designed at the default text size) scaled like `style`.
    /// `traits` nil reads the current text size (what a label wants); a test
    /// passes one to pin it.
    public static func scaled(
        _ font: UIFont,
        relativeTo style: TextStyle,
        maximumPointSize: CGFloat? = nil,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(
            for: font, maximumPointSize: maximumPointSize ?? 0, compatibleWith: traits
        )
    }

    /// The text style's size at the default (Large) text size — the designed
    /// size to hand `scaledSystemFont` when matching a style with a different
    /// weight.
    public static func defaultPointSize(for style: TextStyle) -> CGFloat {
        UIFont.preferredFont(
            forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
    }
}
