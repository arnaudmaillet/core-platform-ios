import CoreModels
import PostGrid
import UIKit

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
    public let willStageDismissal: () -> Void
    /// The close is over, WHICHEVER WAY IT WENT: `true` committed, `false`
    /// sprang back. Both, because what it undoes is set on every dismissal.
    public let dismissalDidEnd: (Bool) -> Void

    public init(
        rowFrame: @escaping (UICoordinateSpace) -> CGRect?,
        captionEnd: CGFloat?,
        depthView: @escaping () -> UIView? = { nil },
        captionTop: CGFloat = 0,
        authorBand: PostAuthorBandView.Model? = nil,
        setConcealed: @escaping (Bool) -> Void = { _ in },
        presentationDidEnd: @escaping (Bool) -> Void = { _ in },
        willStageDismissal: @escaping () -> Void = {},
        dismissalDidEnd: @escaping (Bool) -> Void = { _ in }
    ) {
        self.rowFrame = rowFrame
        self.captionEnd = captionEnd
        self.depthView = depthView
        self.captionTop = captionTop
        self.authorBand = authorBand
        self.setConcealed = setConcealed
        self.presentationDidEnd = presentationDidEnd
        self.willStageDismissal = willStageDismissal
        self.dismissalDidEnd = dismissalDidEnd
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
