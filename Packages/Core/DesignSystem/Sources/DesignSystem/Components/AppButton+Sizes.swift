import UIKit

/// What each `AppButton.Size` draws: its words' font, its insets and the
/// system size its configuration asks for.
extension AppButton {
    /// The button's words' font at `size` — public so a text that stands in
    /// a button's place reads at its size (#2329: the voice panel's timer,
    /// which trades places with its speed chip). `monospacedDigits` for a
    /// number that changes in place.
    public static func titleFont(for size: Size, monospacedDigits: Bool = false) -> UIFont {
        guard monospacedDigits else { return font(for: size) }
        switch size {
        case .row:
            return UIFont.appMonospacedDigitFont(forTextStyle: .subheadline)
        case .compact:
            return UIFont.appMonospacedDigitFont(forTextStyle: .caption1)
        case .header:
            return UIFont.scaledMonospacedDigitSystemFont(
                ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 19
            )
        case .form:
            return UIFont.appMonospacedDigitFont(forTextStyle: .headline)
        }
    }

    /// `traits`: a text size to measure at (tests); nil is the app's.
    static func font(for size: Size, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        switch size {
        case .row:
            UIFont.appFont(forTextStyle: .subheadline)
        case .compact:
            // The like count's type beside it (caption1): a step under the
            // footnote line it stands in, so the words fit the line's height.
            UIFont.appFont(forTextStyle: .caption1, compatibleWith: traits)
        case .header:
            // Capped (#482), as the tray's capsule.
            UIFont.scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 19)
        case .form:
            // The system large button's words: the body's size, semibold.
            UIFont.appFont(forTextStyle: .headline, compatibleWith: traits)
        }
    }

    static func insets(for size: Size) -> NSDirectionalEdgeInsets {
        switch size {
        case .row: NSDirectionalEdgeInsets(top: 6, leading: Spacing.md, bottom: 6, trailing: Spacing.md)
        // No inset above or below: the line's own height is the ground's
        // (the host pins it), so the line never grows for the button.
        case .compact: NSDirectionalEdgeInsets(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)
        case .header: NSDirectionalEdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md)
        case .form:
            NSDirectionalEdgeInsets(
                top: formVerticalInset, leading: Spacing.lg, bottom: formVerticalInset, trailing: Spacing.lg
            )
        }
    }

    /// The system size the configuration asks for; nil keeps the default.
    static func systemButtonSize(for size: Size) -> UIButton.Configuration.Size? {
        switch size {
        case .row: .small
        case .compact: .mini
        case .header, .form: nil
        }
    }

    /// The system large button's height, a `.form` button's at the default
    /// text size: the app's own type scale (#2149) sets its words a little
    /// smaller than Apple's, so the inset makes up the difference.
    static let formHeight: CGFloat = 50
    /// A `.form` button's inset above and below its words: what reaches
    /// `formHeight` at the default size, never under 14 pt — so it grows
    /// with the text from there.
    static var formVerticalInset: CGFloat {
        let base = UIFont.appFont(
            forTextStyle: .headline, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        return max(14, ((formHeight - base.lineHeight) / 2).rounded(.up))
    }
}
