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
/// ⚠️ AND THE SOURCE'S CONCEALMENT IS PART OF THE SETTLEMENT, which it was
/// not. The teardown revealed the marker unconditionally — cancel included —
/// so the first abandoned grab put the tapped marker back on a map that is
/// still covered, and every grab after it flew a card over a marker sitting in
/// plain sight behind the page. Filmed: three grabs in a row, the marker
/// absent under the first and present under the second and third.
///
/// A cancelled grab is a page that is STAYING, so the thing the card
/// impersonates has to stay out of sight — the same contract the reveal family
/// has always had (`RevealDismissInteractionController.finish` runs
/// `setSourceConcealed(cancelled)`), and the two drivers stage the same flight.
/// Nothing is stranded by it: all three source surfaces already restore
/// blanket-fashion when they become the screen again — the map un-hides every
/// annotation view in `viewDidAppear`, For You runs
/// `pager.clearFlightConcealments()`, and the place page
/// `clearLandingConcealment()`.
///
/// Order inside a plan is part of the contract: the page comes back BEFORE
/// anything is taken from the card, and the surface changes hands strictly
/// BEFORE the card is disposed of, or the hand-over would read a card that is
/// already gone.
enum ZoomGrabSettlement {
    enum Action: Equatable {
        /// Put the page back on screen — the abandoned grab, where it is
        /// staying and has been at alpha 0 for the whole gesture.
        ///
        /// ⚠️ FIRST, AND THE ORDER IS THE WHOLE OF IT. The card sits BELOW the
        /// page, so revealing the page covers the card in the same commit and
        /// nothing that happens to the card afterwards can be seen. Taking the
        /// card's picture away first is what put a black frame on screen: the
        /// hand-back hides the card's surface, the card's own ground is the
        /// last rung of the picture ladder — black — and for one composited
        /// frame that ground was the page. Filmed by the user; reproduced at
        /// 2 runs in 8 with the scripted grab, and colour-identified by
        /// tinting each candidate ground separately.
        ///
        /// It is also the order the PRESENT leg already documents as
        /// necessary ("Reveal the page FIRST, then move the surface into it").
        /// The cancel leg was the exact reverse.
        case restoreDestinationContent
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
        /// The flight landed: the marker/tile the card impersonated is the
        /// screen's again.
        case revealSource
        /// The flight did NOT land: the page is staying, so the thing the card
        /// is standing in for must stay out of sight.
        case concealSource
    }

    /// The settlement for a grab that ended.
    ///
    /// - `cancelled`: the release put the page back rather than committing.
    /// - `cardHasLiveSurface`: whether the flight card is carrying a live
    ///   media surface (`zoomLiveMediaSurface != nil`). A cover-only card has
    ///   nothing to hand anywhere.
    static func plan(cancelled: Bool, cardHasLiveSurface: Bool) -> [Action] {
        if cancelled {
            return [.restoreDestinationContent]
                + (cardHasLiveSurface ? [.reclaimSurfaceToDestination] : [])
                + [.removeCardNow, .concealSource]
        }
        // A commit holds the card whether or not it flew live media: the hold
        // is what keeps the landing tile's first composite off screen, and a
        // cover-only landing has the same first-composite gap. The source is
        // revealed UNDER the held card, which is posed exactly over it — so
        // the swap is invisible and the hold decides when the card goes.
        return (cardHasLiveSurface ? [.adoptSurfaceToSource] : [])
            + [.holdCardOverLanding, .revealSource]
    }
}
