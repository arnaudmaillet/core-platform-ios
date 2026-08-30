import Foundation

/// What a released grab must do with its flight card and the live surface it
/// carries — extracted from `ZoomDismissInteractionController.finishTransition`
/// so the decision is unit-testable without a live transition.
///
/// ⚠️ The cancel branch is why this exists. The commit branch always handed
/// the card's surface to the landing source; the cancel branch just removed
/// the card — and under the `AVPlayerLayer` backing the donation had
/// physically taken the page's render view out of its cell, so a cancelled
/// grab left the page it restored with a dead media area. `ZoomAnimator`'s
/// own cancel branch gives donated surfaces back (`zoomReclaimLiveMediaView`);
/// the two drivers stage the same flight and must settle it by the same
/// contract. Under the sample-buffer backing the reclaim is a polite
/// `detachSurface` of the card's twin instead of an ARC drop — the
/// destination's `reclaimDonatedPlayback` branches on the backing, which is
/// exactly why the DECISION here does not.
///
/// Order inside a plan is part of the contract: the surface changes hands
/// strictly BEFORE the card is disposed of, or the hand-over would read a
/// card that is already gone.
enum ZoomGrabSettlement {
    enum Action: Equatable {
        /// Give the card's donated surface back to the destination — the
        /// abandoned grab, where the page stays up and must look untouched.
        case reclaimSurfaceToDestination
        /// Hand the card's surface to the landing source, so the tile is
        /// rendering before the card leaves.
        case adoptSurfaceToSource
        /// Keep the card posed over the landing until the source reports its
        /// own media rendering (the hold owns removing it).
        case holdCardOverLanding
        /// Nothing is landing: the card goes outright.
        case removeCardNow
    }

    /// The settlement for a grab that ended.
    ///
    /// - `cancelled`: the release put the page back rather than committing.
    /// - `cardHasLiveSurface`: whether the flight card is carrying a live
    ///   media surface (`zoomLiveMediaSurface != nil`). A cover-only card has
    ///   nothing to hand anywhere.
    static func plan(cancelled: Bool, cardHasLiveSurface: Bool) -> [Action] {
        if cancelled {
            return (cardHasLiveSurface ? [.reclaimSurfaceToDestination] : []) + [.removeCardNow]
        }
        // A commit holds the card whether or not it flew live media: the hold
        // is what keeps the landing tile's first composite off screen, and a
        // cover-only landing has the same first-composite gap.
        return (cardHasLiveSurface ? [.adoptSurfaceToSource] : []) + [.holdCardOverLanding]
    }
}
