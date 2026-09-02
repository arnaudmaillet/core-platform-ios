import CoreModels
import UIKit

/// The picture a flight home has to show at its DEPARTURE end, over the marker
/// it is landing on.
///
/// A hero card is the SOURCE's twin for the whole flight — the marker's own
/// picture, scaled up to fill the screen and back down again. That is exactly
/// right while the viewer dismisses the post they tapped, and wrong the moment
/// they page: a marker's feed is the whole cluster, so by the third swipe the
/// card takes off wearing a photograph that has not been on screen for three
/// posts, and the first frame of the dismissal is a cut to it.
///
/// The fix is not to re-point the landing. The marker the viewer tapped is
/// still where they left it and still what they expect to fall back onto, so
/// the ARRIVAL stays the post that opened the flight — always, on this surface.
/// What changes is that the card gets a second face for the departure end and
/// dissolves it away on the way home.
///
/// ⚠️ TWO CASES, because the map only ever asks about two. The product rule has
/// a third — a TEXT page dissolving its flat ground into a marker — and it is
/// not here because nothing on this surface can produce it: a settled text page
/// reports `zoomDismissalKind == .card`, both zoom grabs refuse on that before
/// they look at an axis, and the close is claimed by
/// `attachCardCloseAlongsideFlight` and flown to the place gallery instead.
/// Verified, not assumed — `-zoom-blend-log` stays silent for every text page
/// in a cluster, while `[card-close]` reports the drag that actually ran.
enum MapReturnCover: Equatable {
    /// Nothing to reconcile: the card already is what the viewer is leaving.
    /// The flight stays the plain hero it has always been — no second layer, no
    /// dissolve, nothing that can go wrong on the row that was never broken.
    case none
    /// The departure post's own picture, dissolved into the marker's face. Two
    /// opaque photographs, neither carrying text.
    case picture(UIImage)

    /// The operand to hand a `PinCardView`. Nil leaves its blend channel inert.
    func image() -> UIImage? {
        switch self {
        case .none: nil
        case let .picture(image): image
        }
    }

    #if DEBUG
    /// Which row of the product rule this is, for `-zoom-blend-log`. Named
    /// after the rule rather than after the case, so a run can be read against
    /// what was asked for.
    var debugRow: String {
        switch self {
        case .none: "none (same post, or no picture in memory)"
        case .picture: "picture (cross-fade the two media)"
        }
    }
    #endif

    /// Which cover a dismissal onto `arrival` needs, given where the viewer
    /// actually stopped.
    ///
    /// Pure, and separate from every view that uses it, because the row that
    /// must return `none` is the one a mistake here would be invisible on:
    /// dissolving a picture into ITSELF looks like a slightly soft flight, not
    /// like a bug, and it is the row that has always worked.
    ///
    /// - Parameters:
    ///   - departure: where the viewer stopped. Nil (nothing has settled) is
    ///     answered `none` — the card is already the only post there has been.
    ///   - arrival: the post the marker stands for. On this surface that is the
    ///     post the flight opened from; the map never substitutes.
    ///   - picture: the departure's cover, if one can be had. A miss degrades
    ///     to `none` — today's flight — rather than to a blank operand.
    static func resolve(
        departure: PostID?,
        arrival: PostID?,
        picture: (PostID) -> UIImage?
    ) -> MapReturnCover {
        guard let departure, departure != arrival else { return .none }
        guard let image = picture(departure) else { return .none }
        return .picture(image)
    }
}
