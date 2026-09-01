import CoreModels
import PostGrid
import UIKit

/// Where the viewer stopped in a pushed feed, and what that page is drawing.
///
/// The two travel together because a dismissal needs BOTH and they must agree:
/// the id says which post the close is about, the still is what a card has to
/// carry so the window does not cut to something the viewer has not seen.
///
/// ⚠️ THE STILL IS NOT THE ID'S THUMBNAIL. A card takes off full screen and
/// aspect-fills what it is handed, so a small square cover blown up there is a
/// magnified fragment. This is the PAGE's own rendered picture — already the
/// right shape — which is why it is carried rather than looked up.
///
/// Nil id means nothing has settled yet; nil still means the page has no
/// picture to give — which is a TEXT page, and only a text page. A video
/// answers with the frame it is showing, or with the poster it is showing
/// before one arrives; see `VideoRenderView.currentStill`.
public struct SnapFeedSettlement {
    public let postID: PostID?
    public let still: UIImage?
    /// Puts the given surface on the settled page's playback, so a card can
    /// carry the video still PLAYING rather than frozen at the frame the close
    /// began on. Returns whether it took.
    ///
    /// ⚠️ A SECOND surface, never the page's own — the page keeps rendering
    /// behind it. A transition that renders its own window has no handshake to
    /// give a borrowed surface back with, so it may only borrow one nothing
    /// else needs.
    ///
    /// False is ordinary: a still page, a page that stopped playing, or the
    /// single-layer `-avplayer-render` backing where there is no second surface
    /// to be had. The caller carries `still` alone, which is the animation this
    /// improves on rather than replaces.
    public let attachLiveMedia: (UIView) -> Bool

    public init(
        postID: PostID?,
        still: UIImage?,
        attachLiveMedia: @escaping (UIView) -> Bool = { _ in false }
    ) {
        self.postID = postID
        self.still = still
        self.attachLiveMedia = attachLiveMedia
    }
}

/// What the flying card should look like, named without naming the view.
///
/// The two shapes a post is shown in across the app: a mosaic BRICK, which is
/// its media edge to edge, and a timeline ROW's preview, which is one part of a
/// card. The feed feature owns the view that draws each; an origin only has to
/// say which of the two it is.
public enum SnapFeedHeroStyle: Sendable {
    case tile
    case listMedia
}

/// What a surface has to say about the ROW a text-only post is opening from.
///
/// A post with no media has nothing to fly, and for a long time that meant a
/// plain push — which is what `SnapFeedHeroOrigin.hasHero == false` still
/// selects. The reveal replaces the push with a window: the real page,
/// installed at full size, seen through a mask that sweeps from the row's rect
/// to the whole screen. Nothing impersonates anything, so there is no card to
/// describe — only a rect, a cut line, and the three moments the surface has to
/// act on.
///
/// Separate from the flight fields above rather than folded into them, because
/// every one of those describes a CARD (its cover, its style, what to conceal
/// while its twin is in the air) and a reveal has none. An origin that carried
/// both would be answering, for every post, half a set of questions that do not
/// apply to it.
///
/// `nil` on an origin means the surface cannot describe a row — it shows the
/// post as a tile, or does not know where it is — and the plain push is still
/// the honest answer.
@MainActor
public struct TextRevealOrigin {
    /// The row's rect, RE-ASKED at dismissal: the surface may have scrolled.
    /// `nil` means off screen, and the window falls back to a centred one.
    public let rowFrame: (UICoordinateSpace) -> CGRect?
    /// Where the row's caption ends when it is TRUNCATED — the cut below which
    /// the page is veiled, so the window shows no more than the card did.
    /// `nil` when the row shows its whole caption and there is no difference to
    /// hide. Read ONCE, at staging: it is a property of the caption, not of
    /// where the row happens to be, and a row that scrolled out cannot answer.
    public let captionEnd: CGFloat?
    /// The view the depth cue recedes — the content, not the chrome around it.
    public let depthView: () -> UIView?
    /// How far below the row's top edge its caption begins — zero for a row
    /// that shows only its caption, the author band plus its gap for one that
    /// names its author. The window is the WHOLE row, so the destination's
    /// caption has to be told where the row's own sits.
    public let captionTop: CGFloat
    /// Builds the card a DISMISSAL carries home, drawn fresh, rather than the
    /// page seen through a window — see `RevealGeometry.makeDismissStandIn`.
    /// `nil` keeps the page itself, which is still correct for a surface that
    /// cannot draw one.
    ///
    /// Handed WHERE THE VIEWER STOPPED and WHAT THAT PAGE IS SHOWING, which
    /// after any paging is neither the post nor the picture the window opened
    /// from. A source that lands on a fixed place — a marker, a row that must
    /// not be reordered — ignores the id for the purpose of choosing where to
    /// land, and uses the pair to decide what the card must show at the
    /// departure end: the two are different questions, and conflating them is
    /// how a list quietly re-sorted itself under the window.
    public let makeDismissStandIn: (SnapFeedSettlement) -> UIView?
    /// Builds what the OPENING starts as, for a source whose content the page
    /// does not repeat.
    ///
    /// A row does not need one: its caption is the page's caption, so the
    /// window can show the real page from frame 0 and be showing the right
    /// thing. A map's marker is a glyph on a tinted disc, and the page has no
    /// glyph — so without a stand-in the disc would open onto the page's top
    /// left corner, which is a window onto nothing the viewer tapped.
    ///
    /// `nil` is the row's answer and stays the default.
    public let makePresentStandIn: () -> UIView?
    /// Whether the page counter-translates so its caption lands where the
    /// SOURCE's caption is.
    ///
    /// True for a row, whose caption is the same words in the same place — that
    /// alignment is the whole reason the window reads as the card growing.
    /// FALSE for a marker: a disc has no caption, so there is nothing to align
    /// to, and asking anyway drags the page hundreds of points sideways under a
    /// stand-in that is covering it. Measured before this existed: `travel=448`
    /// for a 44pt disc.
    public let alignsPageToSource: Bool
    /// Whether the PAGE itself scales into the window rather than being seen
    /// through it — see `RevealStage.pageCovering`. True for a marker, whose
    /// landing is a 44pt disc and not a card.
    public let pageCoversWindow: Bool
    /// The source's own rounding. `nil` means the card's, which is what every
    /// row is; a marker supplies its own, and for a disc that is half its side.
    public let cornerRadius: CGFloat?
    /// The source's own fill, worn by the page for the length of the reveal and
    /// cross-faded back to its real ground. `nil` means the card's.
    ///
    /// This is the colour transition, and it is not decoration: the window is
    /// the source's shape, so it has to be the source's COLOUR at frame 0 or
    /// the source appears to vanish at the instant it starts growing.
    public let fill: UIColor?
    /// The row's author band, so the destination can borrow it for the flight —
    /// see `RevealGeometry.installDestinationAuthorBand`. `nil` for a row that
    /// names no author, which is every profile gallery's.
    public let authorBand: PostAuthorBandView.Model?
    /// Hide the row while the window taken from it is in the air, and put it
    /// back when it lands — the same bargain the flight fields above strike
    /// with `setConcealed`, for the same reason: a grab moves the window off
    /// the row, and a row left in place is then a second copy of the post the
    /// viewer believes they are holding. See `RevealGeometry.setSourceConcealed`.
    public let setConcealed: (Bool) -> Void
    /// The opening is over: `true` landed, `false` reversed mid-air. For chrome
    /// the opening FADED rather than dismissed.
    public let presentationDidEnd: (Bool) -> Void
    /// Last chance to move before the dismissal measures its landing — pinning
    /// a content inset, or scrolling the row back into view.
    /// Handed the post the viewer actually stopped on, like
    /// `makeDismissStandIn` above and for the same reason: this hook fires
    /// BEFORE the rect and the stand-in are read, so it is the one moment a
    /// source can decide what the close is landing on and move to meet it.
    /// A source that lands on a fixed place ignores it.
    public let willStageDismissal: (PostID?) -> Void
    /// The close is over, WHICHEVER WAY IT WENT: `true` committed, `false`
    /// sprang back. Both, because what it undoes is set on every dismissal.
    public let dismissalDidEnd: (Bool) -> Void

    public init(
        rowFrame: @escaping (UICoordinateSpace) -> CGRect?,
        captionEnd: CGFloat?,
        depthView: @escaping () -> UIView? = { nil },
        captionTop: CGFloat = 0,
        authorBand: PostAuthorBandView.Model? = nil,
        makeDismissStandIn: @escaping (SnapFeedSettlement) -> UIView? = { _ in nil },
        makePresentStandIn: @escaping () -> UIView? = { nil },
        alignsPageToSource: Bool = true,
        pageCoversWindow: Bool = false,
        cornerRadius: CGFloat? = nil,
        fill: UIColor? = nil,
        setConcealed: @escaping (Bool) -> Void = { _ in },
        presentationDidEnd: @escaping (Bool) -> Void = { _ in },
        willStageDismissal: @escaping (PostID?) -> Void = { _ in },
        dismissalDidEnd: @escaping (Bool) -> Void = { _ in }
    ) {
        self.rowFrame = rowFrame
        self.captionEnd = captionEnd
        self.depthView = depthView
        self.captionTop = captionTop
        self.authorBand = authorBand
        self.makeDismissStandIn = makeDismissStandIn
        self.makePresentStandIn = makePresentStandIn
        self.alignsPageToSource = alignsPageToSource
        self.pageCoversWindow = pageCoversWindow
        self.cornerRadius = cornerRadius
        self.fill = fill
        self.setConcealed = setConcealed
        self.presentationDidEnd = presentationDidEnd
        self.willStageDismissal = willStageDismissal
        self.dismissalDidEnd = dismissalDidEnd
    }

    /// A copy with the two chrome callbacks swapped, and EVERYTHING ELSE
    /// carried across.
    ///
    /// ⚠️ This exists so that wrapping cannot drop anything, and it exists
    /// because wrapping dropped four things. A host that pushes the post owns
    /// the tab bar and has to wrap `presentationDidEnd` and `dismissalDidEnd`
    /// around its own dock work; the way to do that was to rebuild the struct
    /// at the call site, and the rebuild silently omitted `captionTop`,
    /// `authorBand`, `makeDismissStandIn` and `setConcealed`.
    ///
    /// Every field here carries a default, so the omission compiled and ran —
    /// and gave a profile gallery a reveal with no stand-in, no borrowed band,
    /// no source concealment (the row sat visible beside the window it was
    /// supposedly inside) and a caption offset of zero. Nothing failed; it just
    /// looked like an older build, which is exactly what it was.
    ///
    /// Add a field to this type and it flows through here for free. Rebuild the
    /// struct by hand instead and you are back to the same defect.
    ///
    /// The caller composes with the originals itself, because the two orders
    /// differ and only the caller knows why.
    public func replacingChrome(
        presentationDidEnd: @escaping (Bool) -> Void,
        dismissalDidEnd: @escaping (Bool) -> Void
    ) -> TextRevealOrigin {
        TextRevealOrigin(
            rowFrame: rowFrame,
            captionEnd: captionEnd,
            depthView: depthView,
            captionTop: captionTop,
            authorBand: authorBand,
            makeDismissStandIn: makeDismissStandIn,
            makePresentStandIn: makePresentStandIn,
            alignsPageToSource: alignsPageToSource,
            pageCoversWindow: pageCoversWindow,
            cornerRadius: cornerRadius,
            fill: fill,
            setConcealed: setConcealed,
            presentationDidEnd: presentationDidEnd,
            willStageDismissal: willStageDismissal,
            dismissalDidEnd: dismissalDidEnd
        )
    }
}

/// Everything the feed needs in order to fly a hero FROM a surface it knows
/// nothing about.
///
/// The alternative was for each feature to write its own `ZoomTransitionSource`
/// — which is what Maps does, and it is a reasonable pattern when the source is
/// genuinely unlike anything else (a pin *is* its own card). A post grid is
/// not: the card that flies is the feed's own `PostGridFlightCard`, and a
/// second feature reimplementing the source around it would either duplicate
/// that view or force it public for the sake of one caller. So the feed keeps
/// the card and the transition, and the origin is the seam.
///
/// Closures rather than a protocol because every question is asked at a
/// different moment — the frame at departure AND again at landing, the
/// concealment twice per flight — and a caller should not have to own an object
/// to answer four of them.
@MainActor
public struct SnapFeedHeroOrigin {
    /// The post itself. The card is built from the same model the origin drew
    /// from, so the two agree by construction rather than by a list of fields
    /// copied across a boundary.
    public let post: GalleryPost
    /// The run of posts the destination is being opened on, `post` first —
    /// the SAME window the caller's `postIDs` names, as models rather than as
    /// identifiers.
    ///
    /// It exists so the destination can render before its own fetch returns.
    /// A route carries ids, and ids are not a page: pushed cold, the feed has
    /// nothing to show until it has fetched, which is a black screen for the
    /// length of the round trip. The origin already drew these posts, so
    /// handing them over costs nothing and removes the wait. Empty is allowed
    /// and simply means "no projection" — the destination then hydrates the
    /// slow way, exactly as before.
    public let stream: [GalleryPost]
    /// Whether there is any media to fly AT ALL.
    ///
    /// ⚠️ Deliberately NOT the same question as `frame` returning nil, and
    /// conflating the two is the bug this field exists to end. A nil frame
    /// means "not on screen right now" — the origin scrolled away mid-flight,
    /// and the answer is a centred collapse. This means "there was never
    /// anything to fly": a text-only post is its words, and it has no media
    /// surface at either end of a flight. One is a transient fact about
    /// scrolling, the other a permanent fact about the post, and the
    /// presentation that follows from each is different — a hero flight in the
    /// first case, a plain push in the second.
    public let hasHero: Bool
    /// The pixels the origin is showing right now, so the card starts as its
    /// twin rather than as an approximation of it.
    public let cover: UIImage?
    public let style: SnapFeedHeroStyle
    /// Where the origin is, in the given space — RE-ASKED at dismissal, since
    /// the surface may have scrolled. `nil` means off screen, and the flight
    /// falls back to a centred collapse rather than flying to a rect nobody
    /// can see.
    public let frame: (UICoordinateSpace) -> CGRect?
    /// Whether the origin is visible at all. Asked separately from `frame`
    /// because a dismissal needs the answer before it has a container space to
    /// measure in.
    public let isOnScreen: () -> Bool
    /// Hide the real thing while its twin is in the air, and put it back after.
    public let setConcealed: (Bool) -> Void
    /// The view the depth cue recedes — the content, not the chrome around it.
    public let depthView: () -> UIView?
    /// How to open this post as a REVEAL when there is no hero to fly — see
    /// `TextRevealOrigin`. `nil` keeps the plain push.
    public let textReveal: TextRevealOrigin?

    public init(
        post: GalleryPost,
        stream: [GalleryPost] = [],
        hasHero: Bool = true,
        cover: UIImage?,
        style: SnapFeedHeroStyle,
        frame: @escaping (UICoordinateSpace) -> CGRect?,
        isOnScreen: @escaping () -> Bool,
        setConcealed: @escaping (Bool) -> Void,
        depthView: @escaping () -> UIView? = { nil },
        textReveal: TextRevealOrigin? = nil
    ) {
        self.post = post
        self.stream = stream
        self.hasHero = hasHero
        self.cover = cover
        self.style = style
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.setConcealed = setConcealed
        self.depthView = depthView
        self.textReveal = textReveal
    }
}
