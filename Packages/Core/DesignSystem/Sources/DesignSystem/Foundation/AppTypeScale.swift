import UIKit

/// The app's own type scale (#2149, the owner 2026-11-05): each text style's
/// size at the default text size, about two points under Apple's — as dense
/// as a social app — and still scaled by Dynamic Type like the style, under
/// the app's ceiling (`TextSizeCeiling`).
///
/// ⚠️ TWO CANDIDATES BEHIND A SWITCH, FOR NOW. The owner compares them on a
/// device (`-type-scale apple|a|b`, DEBUG) and picks one; until then the app
/// draws Apple's sizes, as before. The pick becomes the only scale and the
/// switch goes.
///
/// | Style | Apple | A: social | B: moderate |
/// |---|---|---|---|
/// | largeTitle | 34 | 30 | 32 |
/// | title1 | 28 | 24 | 26 |
/// | title2 | 22 | 20 | 21 |
/// | title3 | 20 | 18 | 19 |
/// | headline (semibold) | 17 | 15 | 16 |
/// | body | 17 | 15 | 16 |
/// | callout | 16 | 14 | 15 |
/// | subheadline | 15 | 13 | 14 |
/// | footnote | 13 | 12 | 13 |
/// | caption1 | 12 | 11 | 12 |
/// | caption2 | 11 | 11 | 11 |
///
/// Nothing under 11 pt at the default size (Apple's minimum). Native chrome
/// (bar titles, the tab bar, search fields, menus, list cells) stays UIKit's.
public enum AppTypeScale: String, Sendable, CaseIterable {
    case apple
    /// A: social (body 15).
    case social = "a"
    /// B: moderate (body 16).
    case moderate = "b"

    /// The smallest size any style takes at the default text size.
    public static let floor: CGFloat = 11

    /// The scale the app draws: Apple's, unless a DEBUG build was launched
    /// with `-type-scale a` or `-type-scale b`.
    public static let current: AppTypeScale = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-type-scale"), index + 1 < arguments.count,
           let scale = AppTypeScale(rawValue: arguments[index + 1].lowercased()) {
            return scale
        }
        #endif
        return .apple
    }()

    /// `style`'s size at the default (Large) text size on this scale; nil on
    /// Apple's, which `preferredFont` already draws.
    public func size(for style: UIFont.TextStyle) -> CGFloat? {
        guard self != .apple, let sizes = Self.sizes[style] else { return nil }
        return self == .social ? sizes.social : sizes.moderate
    }

    private static let sizes: [UIFont.TextStyle: (social: CGFloat, moderate: CGFloat)] = [
        .largeTitle: (30, 32),
        .title1: (24, 26),
        .title2: (20, 21),
        .title3: (18, 19),
        .headline: (15, 16),
        .body: (15, 16),
        .callout: (14, 15),
        .subheadline: (13, 14),
        .footnote: (12, 13),
        .caption1: (11, 12),
        .caption2: (11, 11),
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

    /// Care Mode's floor on this scale: one step up on the app's own sizes,
    /// so its text stays about as large as on Apple's (body ≈ 19 pt).
    public var careModeMinimum: UIContentSizeCategory {
        self == .apple ? .extraLarge : .extraExtraLarge
    }
}
