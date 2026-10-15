import UIKit

/// THE ONE LOOK OF A PERSON IN A BAR (the owner, 2026-10-15): the identity
/// pills of the bars — a vertical post's author and a conversation's peer at
/// the foot, a profile's identity at the top — wear their name at a bar
/// item's own title size (body, semibold) over the handle (caption 2,
/// secondary), the two centred in the pill. One style, so the pills cannot
/// drift apart.
///
/// The name gives way first when the bar is narrow: a half-written name
/// is still recognisable; a half-written handle is no identifier at all.
public enum BarIdentityStyle {
    /// The name: a bar item's title size.
    @MainActor public static var nameFont: UIFont { UIFont.scaledFont(forTextStyle: .body, weight: .semibold) }
    /// The handle, under the name.
    @MainActor public static var handleFont: UIFont { .appFont(forTextStyle: .caption2) }

    /// Dresses a pill's two labels: fonts, inks, and the order they give
    /// way in.
    @MainActor public static func apply(name: UILabel, handle: UILabel) {
        name.font = nameFont
        name.textColor = .label
        handle.font = handleFont
        handle.textColor = .secondaryLabel
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handle.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
}
