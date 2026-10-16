import CoreModels
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// How a shelf's cards describe themselves to the shared flight
/// (`presentSnapFeedHero`) — built by the SHELF (`PostShelfSection.open`,
/// #1271), never by a host: For You, the place page and the search lead row
/// get the same origin from the same place.
///
/// See `ForYouRowOrigins` for the two rules every row origin keeps: every
/// origin carries its window whatever the tapped post is, and a close stages
/// the page before it measures the row.
@MainActor
enum PostShelfOrigins {
    /// A shelf's card: the shelf's posts from it on, flown out of the card — a
    /// list row's media flight (`.listMedia`, the card's own corner), wearing
    /// the card's caption as furniture that fades as it grows.
    ///
    /// `thawsOnLanding` is For You's arrangement: the page is pinned only for
    /// the close, and handed back as it lands. A PUSHED host (the hashtag
    /// page's lead row, #924) passes false: it pins from the tap
    /// (`ForYouGridPage.openHoldingStill`) and hands the inset back in its own
    /// `viewDidAppear`, because both landings here can come while that screen
    /// is still under the depth recede — a grab reveals its source before the
    /// recede is reset — and a thaw then re-bases the list on the scaled
    /// frame's inset: the page dropped 22pt as the card landed.
    static func card(
        _ tapped: GalleryPost,
        stream: [GalleryPost],
        shelf: PostShelfSection,
        page: ForYouGridPage,
        host: UIView,
        thawsOnLanding: Bool = true,
        closeStaged: @escaping () -> Void = {}
    ) -> SnapFeedHeroOrigin {
        let id = tapped.id
        let hasMedia = tapped.kind != .text
        let cover = shelf.cardCover(for: id)
        // Every card in the row is the same size, so the one measured at the
        // tap stands in for a close that finds the card out of its row.
        let tappedSize = shelf.cardFrame(for: id, in: shelf)?.size
        return SnapFeedHeroOrigin(
            // With their live counts (#896): the flight's card draws the
            // number the card it leaves draws.
            post: shelf.livePost(tapped),
            stream: stream.map(shelf.livePost),
            hasHero: hasMedia && shelf.cardFrame(for: id, in: host) != nil,
            cover: cover,
            style: .listMedia,
            frame: { [weak shelf] space in shelf?.cardFrame(for: id, in: space) },
            isOnScreen: { [weak shelf] in shelf?.isCardOnScreen(id) ?? false },
            setConcealed: { [weak shelf, weak page] concealed in
                shelf?.setCardConcealed(concealed, for: id)
                if !concealed, thawsOnLanding { page?.endHeroFreeze() }
            },
            // The card takes off PLAYING, joining its own surface.
            donateLiveMedia: { [weak shelf] in shelf?.liveCardSurface(for: id) },
            depthView: { [weak page] in page },
            // EVERY card — see the note on this type. A text card is the
            // list's own card, and opens and closes as the list's do.
            textReveal: hasMedia
                ? cardReveal(
                    for: tapped, cover: cover, shelf: shelf, page: page,
                    thawsOnLanding: thawsOnLanding, closeStaged: closeStaged
                )
                : textCardReveal(
                    for: tapped, shelf: shelf, page: page,
                    thawsOnLanding: thawsOnLanding, closeStaged: closeStaged
                ),
            // A close hands the page's playback to the card before the flight
            // card goes, and waits for it to draw — no thumbnail between the
            // two (`PostShelfSection.adoptLandingPlayback`).
            adoptLandingLiveMedia: { [weak shelf] view in shelf?.adoptLandingPlayback(view, for: id) },
            landingMediaIsReady: { [weak shelf] in shelf?.isLandingPlaybackReady(for: id) ?? true },
            // A close from another post comes home to this card with the
            // card's OWN clip, parked at the tap (#923) — never the page's.
            returnLiveMedia: { [weak shelf] in shelf?.returnCardSurface(for: id) },
            pauseReturnLiveMedia: { [weak shelf] in shelf?.pauseReturnPlayback(for: id) },
            // Wrapped at the card's own size, and only ever posed after — see
            // `ForYouCardCaptionOverlay`. A media card's: a text card never
            // flies.
            restingOverlay: hasMedia ? { [weak shelf] in
                let size = shelf.flatMap { $0.cardFrame(for: id, in: $0)?.size } ?? tappedSize
                return PostShelfMediaCardCell.makeOverlay(
                    for: shelf?.livePost(tapped) ?? tapped, restingSize: size, imagePipeline: shelf?.imagePipeline,
                    viewerStake: shelf?.cardStake(for: tapped) ?? 0
                )
            } : nil,
            willStageDismissal: { [weak shelf, weak page] in
                ForYouRowOrigins.stageClose(page: page, then: closeStaged) { shelf?.bringCardIntoView(id) }
            }
        )
    }

    /// The window a MEDIA card closes through once the feed is on a text page
    /// — marker-shaped, for the place page's reason
    /// (`PlaceProfileViewController.textRowReveal`): the feed is a pager, so
    /// the card and the page are the same post only until the first swipe.
    /// The card itself, drawn fresh as it rests, is the stand-in.
    static func cardReveal(
        for post: GalleryPost,
        cover: UIImage?,
        shelf: PostShelfSection,
        page: ForYouGridPage,
        thawsOnLanding: Bool = true,
        closeStaged: @escaping () -> Void = {}
    ) -> TextRevealOrigin {
        let id = post.id
        // Handed the shelf rather than capturing it: the closures below hold
        // them weakly, and a nested function naming the parameter would not.
        func standIn(_ shelf: PostShelfSection) -> UIView? {
            guard let size = shelf.cardFrame(for: id, in: shelf)?.size else { return nil }
            // The picture the card is showing NOW, or the one it showed at the
            // tap for a cell that has not drawn it again yet.
            let picture = shelf.cardCover(for: id) ?? cover
            // Drawn as it rests: the live count, a like made in the feed
            // included (#896).
            return PostShelfMediaCardCell.makeStandIn(
                for: shelf.livePost(post), cover: picture, size: size, imagePipeline: shelf.imagePipeline,
                viewerStake: shelf.cardStake(for: post)
            )
        }
        return TextRevealOrigin(
            rowFrame: { [weak shelf] space in
                ForYouRowOrigins.inView(shelf?.cardFrame(for: id, in: space)) {
                    shelf?.bringCardIntoView(id)
                    return shelf?.cardFrame(for: id, in: space)
                }
            },
            captionEnd: nil,
            depthView: { [weak page] in page },
            // Playing the card's parked clip when it has one (#1294).
            makeDismissStandIn: { [weak shelf] _ in
                shelf.flatMap { $0.dressWithReturnClip(standIn($0), for: id) }
            },
            makePresentStandIn: { [weak shelf] in shelf.flatMap(standIn) },
            alignsPageToSource: false,
            pageFit: .covering,
            cornerRadius: PostShelfMediaCardCell.cornerRadius,
            // The card's own ground: the brick's floor — what the cell itself
            // is painted.
            fill: PostGridTileCell.fillColor(for: post),
            setConcealed: { [weak shelf] concealed in shelf?.setCardConcealed(concealed, for: id) },
            willStageDismissal: { [weak shelf, weak page] _ in
                ForYouRowOrigins.stageClose(page: page, then: closeStaged) { shelf?.bringCardIntoView(id) }
            },
            // See `card`'s `thawsOnLanding`.
            dismissalDidEnd: { [weak page, weak shelf] committed in
                shelf?.windowCloseDidEnd(committed, for: id)
                if thawsOnLanding { page?.endHeroFreeze() }
            }
        )
    }

    /// The window a TEXT card opens and closes through — the one Discover's
    /// list opens its text cards through (`ForYouViewController
    /// .installTextReveal`), since the card IS the list's card: the page grows
    /// out of the card with its caption aligned to the card's (`captionTop`),
    /// the card's author band borrowed for the flight, the page veiled below
    /// where the card's two lines stop (`captionEnd`), and the close carrying
    /// the card home as the list's stand-in (`RevealDismissCardView`, at the
    /// row's size and two lines) onto the card it opened from, whatever post
    /// the viewer paged to — the row keeps its order, the list's rule.
    ///
    /// The caption's cut and top are read at the tap, as the list reads them:
    /// properties of the card's caption, which a card scrolled out of the row
    /// could not answer at the close.
    static func textCardReveal(
        for post: GalleryPost,
        shelf: PostShelfSection,
        page: ForYouGridPage,
        thawsOnLanding: Bool = true,
        closeStaged: @escaping () -> Void = {}
    ) -> TextRevealOrigin {
        let id = post.id
        return TextRevealOrigin(
            rowFrame: { [weak shelf] space in
                ForYouRowOrigins.inView(shelf?.cardFrame(for: id, in: space)) {
                    shelf?.bringCardIntoView(id)
                    return shelf?.cardFrame(for: id, in: space)
                }
            },
            captionEnd: shelf.textCardCaptionEnd(for: id),
            depthView: { [weak page] in page },
            captionTop: shelf.textCardCaptionTop(for: id),
            authorBand: shelf.textCardAuthorBand(for: id),
            makeDismissStandIn: { [weak shelf] _ in shelf?.makeTextCardStandIn(for: id) },
            // The list's: the page itself grows out of the card.
            alignsPageToSource: true,
            // The media fills the window, always — see `RevealPageFit.covering`.
            pageFit: .covering,
            // The list's card, its own curve and fill (the initialiser's
            // defaults are the card's).
            setConcealed: { [weak shelf] concealed in shelf?.setCardConcealed(concealed, for: id) },
            willStageDismissal: { [weak shelf, weak page] _ in
                ForYouRowOrigins.stageClose(page: page, then: closeStaged) { shelf?.bringCardIntoView(id) }
            },
            // See `card`'s `thawsOnLanding`.
            dismissalDidEnd: { [weak page] _ in if thawsOnLanding { page?.endHeroFreeze() } }
        )
    }
}
