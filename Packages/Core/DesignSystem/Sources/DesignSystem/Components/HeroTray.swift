import UIKit

/// The buttons a hero header's tray wears — a profile's (Follow, Message,
/// the map pin, the QR code, "...") and a place's (Pin, the QR code) — in
/// one place, so the two trays cannot drift apart. Moved out of
/// `ProfileHeaderView` on 5 October 2026, unchanged.
public enum HeroTray {
    /// A tray bubble's side, and so the tray's height.
    public static let bubbleSize: CGFloat = 44

    /// The tray's text capsules, FLAT.
    ///
    /// ⚠️ NOT GLASS. Liquid Glass is a material for chrome that floats over
    /// content — it earns its place by showing what passes beneath it. These
    /// buttons sit on the page with nothing behind them, so glass here was
    /// a blur of a flat grey, which reads as a rendering fault rather than
    /// as depth. The platform's own answer for a button on a page is the
    /// filled family: one PROMINENT capsule in the tint, for the action the
    /// screen invites (Follow), and quiet grey capsules with page ink for
    /// the rest (Following, Message, Edit Profile). That is the pairing every
    /// profile screen on the platform has settled on, and it is the same
    /// grey the cards' pills wear, so the tray and the list read as one
    /// system.
    ///
    /// ⚠️ OPAQUE (user, 30 September 2026: the buttons were "a bit
    /// transparent"). The platform's `.gray()` is a translucent fill, made to
    /// be seen on the page — on a poster the tray stands on the picture's
    /// foot, and the picture showed through every quiet button. They are
    /// `.filled()` in `trayFill`, the grey they wore on the page, so nothing
    /// changes where there is no picture, and the system's own highlight and
    /// disabled treatments still apply.
    public static func capsule(prominent: Bool) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        if !prominent {
            config.baseBackgroundColor = fill
            config.baseForegroundColor = .label
        }
        config.cornerStyle = .capsule
        // md, not lg, side insets: the capsule shares the avatar-side column
        // with three bubbles; the tighter title keeps the tray within budget.
        config.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        )
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            // Capped (#482): the capsule shares its row with three bubbles.
            attributes.font = UIFont.scaledSystemFont(
                ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 19
            )
            return attributes
        }
        return config
    }

    /// The quiet buttons' grey: the platform's gray-button fill
    /// (`secondarySystemFill` — measured, see the test
    /// `theOpaqueGreyIsTheGrayButtonOnThePage`) laid over the page once, so
    /// it is the tone those buttons showed on the page — without the
    /// translucency that let a poster's picture through (see `capsule`).
    public static let fill = UIColor { traits in
        var fill = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var page = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        UIColor.secondarySystemFill.resolvedColor(with: traits)
            .getRed(&fill.r, green: &fill.g, blue: &fill.b, alpha: &fill.a)
        Surface.page.resolvedColor(with: traits).getRed(&page.r, green: &page.g, blue: &page.b, alpha: &page.a)
        return UIColor(
            red: page.r + (fill.r - page.r) * fill.a,
            green: page.g + (fill.g - page.g) * fill.a,
            blue: page.b + (fill.b - page.b) * fill.a,
            alpha: 1
        )
    }

    /// A circular flat bubble holding a single SF Symbol, in the same opaque
    /// grey as the quiet capsules beside it, with page ink.
    public static func bubble(systemImage: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = fill
        config.baseForegroundColor = .label
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: systemImage)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        config.contentInsets = .zero
        return config
    }
}
