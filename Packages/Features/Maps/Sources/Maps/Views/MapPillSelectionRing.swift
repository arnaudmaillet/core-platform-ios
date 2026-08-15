import UIKit

/// The accent rim a selected pill wears when it has nowhere else to say so.
///
/// Selection is normally carried by the CONTENT: the glyph and title turn
/// accent blue against a frosted lift. A title-less pill showing a
/// photograph has neither — the avatar fills the circle edge to edge, so the
/// frosted fill sits behind it, the hairline under it, and the tint applies
/// to a symbol that is not being drawn. Selected and unselected people pills
/// rendered identically; only the rim is left to carry it.
///
/// So the ring is not decoration added to every pill: it appears exactly
/// where the existing cue cannot be seen. A capsule keeps its blue semibold
/// title (a selected primary expands into one, which is why morphing pills
/// are excluded the moment they stop being circles) and gains no rim.
struct MapPillSelectionRing: Equatable {
    let strokeWidth: CGFloat
    /// How far outside the pill the stroke is drawn. The ring sits BEYOND the
    /// glass rim rather than over it: the avatar is inset by
    /// `MapPillButton.avatarInset`, and a ring drawn inward would eat that
    /// hairline of glass — the one thing separating an accent rim from a
    /// photograph that might itself be blue.
    let outset: CGFloat
    /// A soft accent halo under the rim. It is what keeps the ring legible on
    /// a dark map, where a thin blue line can otherwise sit on water or park
    /// green with little to separate it.
    let glowRadius: CGFloat
    let glowOpacity: CGFloat

    var isVisible: Bool { strokeWidth > 0 }

    static let none = MapPillSelectionRing(
        strokeWidth: 0, outset: 0, glowRadius: 0, glowOpacity: 0
    )

    /// 3pt on a 48pt circle: a twelfth of the diameter, which reads as a rim
    /// at arm's length without closing in on the face.
    static let ringed = MapPillSelectionRing(
        strokeWidth: 3, outset: 1.5, glowRadius: 5, glowOpacity: 0.45
    )

    static func resolve(selected: Bool, isCircular: Bool) -> MapPillSelectionRing {
        selected && isCircular ? .ringed : .none
    }
}
