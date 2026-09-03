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
/// ## No longer a prototype
///
/// It shipped behind `-text-reveal`, DEBUG only, for as long as it was one
/// screen's experiment. It is now how a text post opens, everywhere it applies
/// and in every build: a text post had no media to fly and so opened with a
/// plain slide while every other post got a hero, and that gap is what this
/// closes. Leaving it behind a flag meant the app shipped the gap.
///
/// `-no-text-reveal` remains, DEBUG only, as the way back — the A/B side for
/// anything that needs to compare against the plain push.
@MainActor
enum TextRevealInstaller {
    /// Whether the reveal is on for this launch. On unless a debug build asks
    /// for the old plain push.
    static var isEnabled: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-no-text-reveal")
        #else
        true
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
    /// The tone of the thing the viewer tapped — one decision, two consumers.
    ///
    /// A marker gives its disc's tint, a list row the card's fill, a tile its
    /// own (dark for a video). Written once here for the reason the file
    /// already gives about the fill: three copies of one colour is how two
    /// surfaces stop matching.
    static func sourceFill(for origin: TextRevealOrigin) -> UIColor {
        origin.fill ?? PostGridListRowCell.cardFillColor
    }

    static func geometry(
        feed: UIViewController, origin: TextRevealOrigin, pipeline: ImagePipeline?
    ) -> RevealGeometry {
        // ⚠️ THE GROUND THE FILL IMPLIES, handed over before the window opens.
        //
        // The reveal lends this tone to the page through `setRevealGroundTint`,
        // which lands on the ACTIVE CELL — and a feed pushed before its corpus
        // arrives has none, so on a cold open the loan is dropped and the
        // window opens onto black. This is the same decision, made where it
        // cannot be dropped: the screen's own pre-data ground. All three reveal
        // surfaces funnel through here, so it is one line for the map, For You
        // and the place page alike.
        (feed as? SnapFeedViewController)?.setEmptyGround(sourceFill(for: origin))
        // …and what is DRAWN on it. The line above says what colour the window
        // is; this puts the screen it is opening onto on top, in the state it
        // is actually in. Reached only by the text-reveal branch, so a
        // photograph is never promised comment bones — and run synchronously
        // before the push, so the panel exists before the animator lays the
        // destination out and its build is paid outside the flight.
        (feed as? SnapFeedViewController)?.presentLoadingPage()
        return RevealGeometry(
            sourceFrame: origin.rowFrame,
            // The CARD's shape unless the source says otherwise, which is every
            // row and is why these are defaults rather than arguments. A map's
            // marker is a disc in its own tint and supplies both.
            //
            // The card's values are read from PostGrid rather than restated,
            // for the same reason the insets are: three copies of one colour is
            // how two surfaces stop matching.
            sourceCornerRadius: origin.cornerRadius ?? PostGridListRowCell.cardCornerRadius,
            sourceFill: sourceFill(for: origin),
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
            // Re-asked at dismissal like `anchorFrame` above, and for the same
            // reason turned inside out: the viewer may have paged, so the post
            // the source is being asked to draw is not the post it was opened
            // from. The source decides what that means — a marker draws its own
            // face regardless; a row keeps its own position and does the same.
            makeDismissStandIn: { [weak feed] in
                origin.makeDismissStandIn((feed as? SnapFeedViewController)?.activePostID)
            },
            makePresentStandIn: origin.makePresentStandIn,
            setSourceConcealed: origin.setConcealed,
            depthView: origin.depthView,
            presentationDidEnd: origin.presentationDidEnd,
            // Told where the viewer stopped, exactly as the stand-in above
            // is: it runs before anything is measured, so a source that wants
            // to land on the settled post has to learn of it here or move
            // after the rect has already been read.
            willStageDismissal: { [weak feed] in
                origin.willStageDismissal((feed as? SnapFeedViewController)?.activePostID)
            },
            dismissalDidEnd: origin.dismissalDidEnd,
            // A source that has no caption cannot be aligned to, whatever the
            // launch argument says: asking anyway slid the page 448pt sideways
            // under a 44pt disc that was covering it.
            matchesAnchor: matchesAnchor && origin.alignsPageToSource,
            pageFit: origin.pageFit
        )
    }
}
