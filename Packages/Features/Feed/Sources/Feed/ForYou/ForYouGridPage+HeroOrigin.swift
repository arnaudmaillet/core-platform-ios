import FeedInterface
import MediaPlayback
import PostGrid
import UIKit

extension ForYouGridPage {
    /// The one description of a tile — or a list row — opening its post through
    /// the shared flight (`FeedFeatureBuilder.presentSnapFeedHero`), for every
    /// host of this page that is not For You itself (#1270, epic #1269).
    ///
    /// ⚠️ ONE CONTRACT FOR EVERY MEDIA TILE (the owner, 2026-10-16). Each host
    /// used to build this origin by hand — forty lines apiece, drifting apart —
    /// and none of them passed the landing's playhead hooks: a close back onto
    /// the same post never handed the page's playback to the tile, which
    /// started its clip again. Everything a tile is, is answered here; a host
    /// passes only what is its own.
    ///
    /// Opens the handoff scope as a side effect — the tapped tile's player is
    /// the flight's from here, with its clip parked for a close that pages on
    /// (#923/#951). Call it exactly where the host commits to opening.
    ///
    /// - Parameters:
    ///   - textReveal: the window a text post opens through, and any post
    ///     closes through once the feed has paged onto words — the host's
    ///     (`tileWindow`, a list's row reveal), or nil.
    ///   - opensComments: the post opens on its thread.
    ///   - willStageDismissal: what the host adds before a close is measured.
    ///   - pinsBeforeClose: the page is pinned (`pinForPushedClose`) before
    ///     that — for a host whose push holds it still (`openHoldingStill`).
    ///     False for a host that manages its own freeze (the place page).
    ///   - continuation: on past the window into the host's next posts.
    func heroOrigin(
        opening tapped: GalleryPost,
        stream: [GalleryPost],
        in host: UIView,
        textReveal: TextRevealOrigin?,
        opensComments: Bool = false,
        willStageDismissal: @escaping () -> Void = {},
        pinsBeforeClose: Bool = true,
        continuation: SnapFeedContinuation?
    ) -> SnapFeedHeroOrigin {
        let id = tapped.id
        let appearance = heroAppearance(for: id)
        let index = posts.firstIndex { $0.id == id }
        beginPlaybackHandoff(of: id, parkingReturn: true)
        return SnapFeedHeroOrigin(
            // With their live counts (#896, `post(for:)`): the flight's card
            // draws the number the tile it leaves draws.
            post: post(for: id) ?? tapped,
            stream: stream.map { post(for: $0.id) ?? $0 },
            hasHero: hero(for: id, in: host) != nil,
            cover: appearance?.cover,
            // The page that drew the thing knows what shape it drew: a brick,
            // or a row's (or a paired card's) media.
            style: appearance?.style == .listMedia ? .listMedia : .tile,
            frame: { [weak self] space in self?.hero(for: id, in: space)?.frame },
            isOnScreen: { [weak self] in self?.isPostVisible(id) ?? false },
            setConcealed: { [weak self] concealed in self?.setHeroHidden(concealed, for: id) },
            // The card takes off PLAYING, joining the tile's own surface.
            donateLiveMedia: { [weak self] in self?.liveFlightSurface(for: id) },
            opensComments: opensComments,
            depthView: { [weak self] in self },
            textReveal: textReveal,
            // ⚠️ A CLOSE ONTO THE SAME POST CONTINUES ITS PLAYHEAD: the tile
            // takes the surface the card flew and the card waits for it to
            // draw — For You's own landing (`ForYouGridZoomSource`).
            adoptLandingLiveMedia: { [weak self] view in
                guard let view = view as? VideoRenderView else { return }
                self?.adoptLivePlayback(view, for: id)
            },
            landingMediaIsReady: { [weak self] in self?.isLandingPlaybackReady(for: id) ?? true },
            // A close from another post comes home with the tile's OWN clip,
            // parked at the tap (#951) — never the page's.
            returnLiveMedia: { [weak self] in self?.returnFlightSurface(for: id) },
            pauseReturnLiveMedia: { [weak self] in self?.pauseReturnPlayback(for: id) },
            adoptReturnLiveMedia: { [weak self] view in self?.landReturnPlayback(view, for: id) },
            returnLandingIsReady: { [weak self] in self?.isReturnLandingReady(for: id) ?? true },
            // The tile's words, worn on a close and faded in as it shrinks.
            restingOverlay: { [weak self] in self?.restingOverlay(for: id) },
            // A tile's heart flies red once the viewer has staked.
            viewerStake: { [weak self] in self?.viewerStake(on: id) ?? 0 },
            // Pinned since the tap; pinned again in case a refused push or a
            // cancelled window close handed the inset back meanwhile.
            willStageDismissal: { [weak self] in
                if pinsBeforeClose { self?.pinForPushedClose() }
                willStageDismissal()
            },
            // The carousel's page the row is on, and the row following the
            // post's carousel back, so the close lands on the page left open.
            mediaPage: index.flatMap { currentMediaPage(atIndex: $0) },
            followMediaPage: { [weak self] id, mediaPage in self?.setMediaPage(mediaPage, for: id) },
            // A row draws the page it is on (`renderedCover`), and that page
            // outlives the viewer swiping on to another post (#1332).
            currentCover: { [weak self] in self?.heroAppearance(for: id)?.cover },
            continuation: continuation
        )
    }

    /// The window a post closes through when there is no picture to fly — a
    /// TEXT post, or any post once the feed has paged onto words — for the
    /// tile or row it sits on: the tile's own window (`tileWindow`), or the
    /// row's card (#1273, the hosts' copies made one).
    ///
    /// - Parameters:
    ///   - alignsPageToSource: the page grows out of the card caption on
    ///     caption, the row's author band borrowed for the flight — honest only
    ///     while the row and the page are the same post (search's cards, the
    ///     profile's). False holds the page still and opens the card over it
    ///     (a pager-backed list).
    ///   - willStageDismissal: brings the post back clear of the chrome and
    ///     pins the page before the landing is measured.
    ///   - dismissalDidEnd: whether the close committed.
    func closeWindow(
        for post: GalleryPost,
        alignsPageToSource: Bool,
        willStageDismissal: @escaping () -> Void,
        dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin? {
        let anchor = post.id
        if drawsAsTile(anchor) {
            return tileWindow(for: post, willStageDismissal: willStageDismissal, dismissalDidEnd: dismissalDidEnd)
        }
        guard rowFrame(for: anchor, in: self) != nil else { return nil }
        return TextRevealOrigin(
            // The text row's rect, or any row's: the anchor may be a media
            // row, which `textRowFrame` refuses on purpose.
            rowFrame: { [weak self] space in
                self?.textRowFrame(for: anchor, in: space) ?? self?.rowFrame(for: anchor, in: space)
            },
            // Read once, at the tap, while the row is realized by definition.
            captionEnd: alignsPageToSource ? textRowCaptionEnd(for: anchor) : nil,
            depthView: { [weak self] in self },
            captionTop: alignsPageToSource ? textRowCaptionTop(for: anchor) : 0,
            authorBand: alignsPageToSource ? textRowAuthorBand(for: anchor) : nil,
            makeDismissStandIn: { [weak self] _ in self?.makeDismissStandIn(for: anchor) },
            alignsPageToSource: alignsPageToSource,
            // The media fills the window, always — see `RevealPageFit.covering`.
            pageFit: .covering,
            // The list's card, its own curve and fill (the initialiser's
            // defaults are the card's).
            setConcealed: { [weak self] concealed in self?.setRevealConcealed(concealed, for: anchor) },
            willStageDismissal: { _ in willStageDismissal() },
            dismissalDidEnd: dismissalDidEnd
        )
    }
}
