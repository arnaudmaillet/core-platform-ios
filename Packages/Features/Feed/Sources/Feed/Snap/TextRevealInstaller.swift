import CoreNavigation
import FeedInterface
import MediaCore
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

    /// Where the borrowed band goes, given the page's caption ROW.
    ///
    /// Pure, and separated out because it is arithmetic that was wrong once and
    /// looked right: the first version measured from the page's own edge and
    /// put the band 16pt wider on each side than the card's. The page's caption
    /// is inset TWICE — once by the stream's section, once by the row — and
    /// only the second of those is the card's own. Anchoring to the row rather
    /// than to the view is what makes the two agree.
    ///
    /// Vertically it sits where the CARD puts its band above its caption, so a
    /// window landing on the card's rect lands one band on the other:
    /// `captionOffset` up from the caption, then back down by the inset the
    /// card keeps above it.
    static func bandRect(anchoredTo anchor: CGRect) -> CGRect {
        let inset = PostGridListRowCell.captionInset
        return CGRect(
            x: anchor.minX + inset,
            y: anchor.minY - PostAuthorBandView.captionOffset
                + PostGridListRowCell.captionTopInset,
            width: max(0, anchor.width - inset * 2),
            height: PostAuthorBandView.avatarDiameter
        )
    }

    /// The geometry both legs read — forwards on the push, backwards on the
    /// pop. One rect calculation, so the two can never disagree.
    static func geometry(
        feed: UIViewController, origin: TextRevealOrigin, pipeline: ImagePipeline?
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
            // Placed HERE rather than in the transition, because turning the
            // page's caption anchor into the band's y needs the card's own
            // insets — and those live in PostGrid, which CoreNavigation cannot
            // see. The band sits where the CARD puts it above its caption, so
            // that a window landing on the card's rect lands one on the other.
            installDestinationAuthorBand: { [weak feed] anchor in
                guard let anchor, let band = origin.authorBand else {
                    (feed as? SnapFeedViewController)?
                        .installRevealAuthorBand(in: nil, model: nil, pipeline: nil)
                    return
                }
                (feed as? SnapFeedViewController)?.installRevealAuthorBand(
                    in: bandRect(anchoredTo: anchor),
                    model: band,
                    pipeline: pipeline
                )
            },
            setDestinationAuthorBandOpacity: { [weak feed] alpha in
                (feed as? SnapFeedViewController)?.setRevealAuthorBandOpacity(alpha)
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
            sourceCaptionTop: origin.captionTop,
            makeDismissStandIn: origin.makeDismissStandIn,
            setSourceConcealed: origin.setConcealed,
            depthView: origin.depthView,
            presentationDidEnd: origin.presentationDidEnd,
            willStageDismissal: origin.willStageDismissal,
            dismissalDidEnd: origin.dismissalDidEnd,
            matchesAnchor: matchesAnchor
        )
    }
}
