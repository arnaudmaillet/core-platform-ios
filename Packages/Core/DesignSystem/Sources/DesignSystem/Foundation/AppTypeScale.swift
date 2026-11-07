import UIKit

/// The app's own type scale (#2149, the owner 2026-11-05): each text style's
/// size at the default text size, a point or two under Apple's — as dense as
/// a social app — and still scaled by Dynamic Type like the style, under the
/// app's ceiling (`TextSizeCeiling`).
///
/// ⚠️ ONE SCALE. The owner compared two on his iPhone (A: social, body 15;
/// B: moderate, body 16) against Apple's and picked B (2026-11-06); the
/// DEBUG switch that kept A and Apple's a launch argument away went when
/// #2149 closed.
///
/// | Style | Apple | App |
/// |---|---|---|
/// | largeTitle | 34 | 32 |
/// | title1 | 28 | 26 |
/// | title2 | 22 | 21 |
/// | title3 | 20 | 19 |
/// | headline (semibold) | 17 | 16 |
/// | body | 17 | 16 |
/// | callout | 16 | 15 |
/// | subheadline | 15 | 14 |
/// | footnote | 13 | 13 |
/// | caption1 | 12 | 12 |
/// | caption2 | 11 | 11 |
///
/// Nothing under 11 pt at the default size (Apple's minimum). Native chrome
/// (bar titles, the tab bar, search fields, menus, list cells) stays UIKit's.
public enum AppTypeScale {
    /// The smallest size any style takes at the default text size.
    public static let floor: CGFloat = 11

    /// `style`'s size at the default (Large) text size; nil for a style the
    /// table does not name, which `preferredFont` draws.
    public static func size(for style: UIFont.TextStyle) -> CGFloat? {
        sizes[style]
    }

    private static let sizes: [UIFont.TextStyle: CGFloat] = [
        .largeTitle: 32,
        .title1: 26,
        .title2: 21,
        .title3: 19,
        .headline: 16,
        .body: 16,
        .callout: 15,
        .subheadline: 14,
        .footnote: 13,
        .caption1: 12,
        .caption2: 11,
    ]

    /// Whether Bold Text is on, readable where a font is made off the main
    /// actor; kept by `TextSizeCeiling.apply` (`UIAccessibility` is the main
    /// actor's).
    nonisolated(unsafe) public internal(set) static var boldText = false

    /// The weight a style draws at: headline's semibold, the rest regular —
    /// a step heavier with Bold Text on, as `preferredFont` would.
    static func weight(for style: UIFont.TextStyle, boldText: Bool) -> UIFont.Weight {
        let base: UIFont.Weight = style == .headline ? .semibold : .regular
        guard boldText else { return base }
        return base == .semibold ? .bold : .semibold
    }

    /// Care Mode's floor: one step over Apple's Extra Large, so its text
    /// stays about as large as Care Mode's on Apple's sizes (body ≈ 19 pt).
    public static let careModeMinimum: UIContentSizeCategory = .extraExtraLarge
}
