import CoreNavigation
import FeedInterface
import PostGrid
import UIKit

/// Builds the reveal's geometry for any surface that shows a post as a LIST ROW.
///
/// ## Why this is not a second copy
///
/// Two screens draw a text post as a row — For You's grid and a profile's
/// gallery — and a viewer opening the same post from either is looking at one
/// screen and must get one transition. That is easy to say and easy to lose:
/// the geometry has thirteen fields, four of them measured, and a second
/// hand-written copy would agree on the day it was written and drift from the
/// first correction onward. Every number here that describes the CARD — its
/// rounding, its fill, where its caption ends, how the destination is veiled
/// and tinted — is therefore written once.
///
/// What is left to the surface is what genuinely differs, and it is only ever
/// choreography: which chrome comes back with the return, and what has to
/// settle before a landing is measured. Those arrive as a `TextRevealOrigin`.
///
/// ## The prototype gate
///
/// `-text-reveal`, and DEBUG only, exactly as it has been. Wiring a second
/// surface does not promote the prototype — it means the one flag now turns the
/// transition on everywhere it applies, instead of on one screen out of two.
@MainActor
enum TextRevealInstaller {
    /// Whether the prototype is on for this launch.
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-text-reveal")
        #else
        false
        #endif
    }

    /// Whether the page counter-translates to match its caption to the row's,
    /// or simply sits still while the window opens over it. A matter of taste
    /// that no argument settles, so the prototype exposes both.
    static var matchesAnchor: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-text-reveal-plain")
        #else
        true
        #endif
    }

    /// The geometry both legs read — forwards on the push, backwards on the
    /// pop. One rect calculation, so the two can never disagree.
    static func geometry(
        feed: UIViewController, origin: TextRevealOrigin
    ) -> RevealGeometry {
        RevealGeometry(
            sourceFrame: origin.rowFrame,
            sourceCornerRadius: PostGridListRowCell.cardCornerRadius,
            // The card's own fill, borrowed by the page for the length of the
            // reveal. Read from PostGrid rather than restated, for the same
            // reason the radius and the insets are: three copies of one colour
            // is how two surfaces stop matching.
            sourceFill: PostGridListRowCell.cardFillColor,
            sourceCaptionEnd: origin.captionEnd,
            installDestinationVeil: { [weak feed] cut, tint in
                (feed as? SnapFeedViewController)?.installRevealVeil(below: cut, tint: tint)
            },
            setDestinationVeilOpacity: { [weak feed] alpha in
                (feed as? SnapFeedViewController)?.setRevealVeilOpacity(alpha)
            },
            setDestinationGround: { [weak feed] color in
                (feed as? SnapFeedViewController)?.setRevealGroundTint(color)
            },
            // Re-asked at dismissal, not captured: the viewer may have paged
            // the feed to a different post, whose caption is a different
            // height. Reading it live means the close aims at what is on
            // screen rather than at what was there on the way in.
            anchorFrame: { [weak feed] space in
                (feed as? SnapFeedViewController)?.revealCaptionAnchor(in: space)
            },
            depthView: origin.depthView,
            presentationDidEnd: origin.presentationDidEnd,
            willStageDismissal: origin.willStageDismissal,
            dismissalDidEnd: origin.dismissalDidEnd,
            matchesAnchor: matchesAnchor
        )
    }
}
