import Foundation

/// How a landed PRESENT is settled: what runs on the animation's clock, and
/// what waits for the page to have something to show.
///
/// # Why this is a type
///
/// Because the split is the product rule, and it was a single closure.
///
/// The animator used to do all of it inside one readiness gate — reveal the
/// page, adopt the surface, drop the card, and call `completeTransition` —
/// under `whenReady(ceiling: 3.0s, condition: contentIsReady && mediaIsRendering)`.
/// So a present took as long as the post took to arrive. Measured on the map
/// route, nine presents at `-mock-latency 700`:
///
///     before   577  631  637  656  804  851  1526  1707  3745  ms
///     after    491  496  501  502  505  561   566   569   570  ms
///
/// Same gesture, same build, one line apart. The rule the product asks for is
/// that every animation of a kind takes about the same time, and that media —
/// video above all — is decoupled from it: if the picture is not there yet,
/// the window shows the rung below and swaps the better one in when it lands.
///
/// ⚠️ WHAT THE GATE WAS PROTECTING IS STILL PROTECTED. It was not superstition:
/// revealing an unhydrated feed shows its flat ground, and revealing a hydrated
/// page whose media area is compositing nothing shows the cell's black floor —
/// both filmed, both recorded in `ZoomAnimator`. The difference is WHO waits.
/// The card is no longer the transition's hostage: it is parked as an inert
/// COVER over the page, and the same readiness condition, under the same
/// ceiling, decides when to drop it. Nothing waits on that.
///
/// The one structural requirement is in `parkCardAsCover`: the card is staged
/// BELOW the destination, so a reveal covers it. It has to move above the page
/// — into the destination's own view, which is also what lets it outlive the
/// transition container.
enum ZoomPresentSettlement {
    enum Action: Equatable {
        /// The page comes out from behind the card.
        case revealDestination
        /// The card stops being part of the transition and becomes an inert
        /// full-bleed cover owned by the destination — above the page, so the
        /// reveal cannot hide it, and touch-transparent, so the screen belongs
        /// to the viewer again.
        case parkCardAsCover
        /// The flight's touch shield goes: the transition is over.
        ///
        /// ⚠️ It used to be removed inside the readiness gate, so a slow page
        /// meant up to three seconds in which the screen accepted no touches
        /// at all.
        case dropShield
        /// Reset the presenter's depth cue and drop the flight's own furniture.
        case clearFlightFurniture
        /// Tell UIKit. On the animation's clock, always.
        case completeTransition
        /// Hand the cover's live surface to the page, so the page renders the
        /// frame the cover was showing rather than starting a layer of its own.
        ///
        /// ⚠️ AFTER THE REVEAL, ALWAYS, and the reason predates this split: an
        /// `AVPlayerLayer` only renders inside a VISIBLE hierarchy, so
        /// installing it into still-hidden content stops it and drops
        /// `isReadyForDisplay` for ~165ms — the flash at the end of the flight.
        /// The two phases make that ordering structural rather than a comment:
        /// the reveal is on the animation's clock and this is not.
        case adoptSurfaceToDestination
        /// The page has a picture: the cover is not needed any more.
        case dropCover
    }

    /// Everything that happens when the flight lands, whatever the media is
    /// doing. Ordered, and the order is the contract: the page is revealed
    /// first, the card is parked above it in the same commit — so no frame can
    /// show one without the other — and only then is UIKit told.
    static func onSchedule() -> [Action] {
        [.dropShield, .revealDestination, .parkCardAsCover,
         .clearFlightFurniture, .completeTransition]
    }

    /// Everything that waits for the page to have something to show. Nothing
    /// in the transition depends on it.
    ///
    /// - `cardHasLiveSurface`: a cover-only card has nothing to hand over.
    static func whenDestinationReady(cardHasLiveSurface: Bool) -> [Action] {
        (cardHasLiveSurface ? [.adoptSurfaceToDestination] : []) + [.dropCover]
    }
}
