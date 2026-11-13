import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// MARK: - Timeline row

/// One full-width row of the Activity/Short timelines: the caption with
/// reading padding on a soft card, plus — when the post carries media — a
/// rounded full-width preview under the text (play badge for videos). Short
/// pages never have media, so their rows are text + metadata.
///
/// ## Where the metadata sits
///
/// Views, reactions, comments and the post's compact age, and there are two
/// placements because there are two shapes of card:
///
/// * **Text row** — a quiet line closing the card, the age leading and the
///   counters trailing, `.secondaryLabel` against the card's own fill.
/// * **Media row** — the same four values ON the preview, as material chips
///   resting on its bottom edge: the age leads and the counters close the row,
///   with the page indicator joining them at the trailing end. The card then
///   ENDS at the preview, so the line
///   below it is gone rather than duplicated.
///
/// ⚠️ Both placements read the same way round, and a mosaic TILE follows the
/// half of the rule it can: it carries no date, but its counters close its row
/// at the trailing edge like everything else. The numbers are in the same
/// corner on every surface, so the eye never has to look elsewhere for them.
///
/// The second is not decoration. A card with a preview closed on a strip of
/// card-coloured furniture below the image, which is the widest thing on the
/// row and the least worth reading; moving it onto the media buys back roughly
/// 28pt per media row and lets the preview finish the card. See
/// `PostMetaPillView` for the ground the pills stand on, and `contentInset` for
/// why the preview's edges fall on the caption's.
public final class PostGridListRowCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    public static let reuseID = "PostGridListRowCell"
    /// The inner preview's rounding — the radius a hero flying from this row
    /// must start at (`PostGridFlightCard.Style.listMedia`), so the flight is
    /// the preview's twin rather than its approximation. A NUMBER, not a
    /// corner configuration: the hero reads it to open a flight at, and a
    /// configuration resolved at layout time is not something a transition
    /// can ask for up front.
    ///
    /// ⚠️ ITS OWN CONSTANT since the list rows lost their card (#2290). It
    /// was derived from the card's, concentric: 26 − the preview's 12pt inset.
    /// A row has no card around its preview any more, so nothing is left to
    /// be concentric with; the value is kept (14) and #2289 owns any change.
    /// A shelf's media card wears it too (`PostShelfMediaCardCell`), and a
    /// voice post's panel (#2329): the token is DesignSystem's
    /// (`Surface.mediaCornerRadius`), so VoiceKitUI reaches it.
    public static let mediaCornerRadius: CGFloat = Surface.mediaCornerRadius

    /// Where the page STOPS MATCHING this card, in the card's own space — the
    /// reveal's cut line. Below it the destination is veiled for the length of
    /// a flight, so the window shows no more of itself than the card does.
    ///
    /// ## Two answers, one rule
    ///
    /// The rule is not about truncation, though it was written as if it were.
    /// A card shows a caption and a metric line; the page shows the same
    /// caption, the same metric line, and then its comments and its composer.
    /// The cut is wherever the two part company:
    ///
    /// * **Truncated caption** — they part at the card's fourth line, because
    ///   the page has a fifth. Measured on an iPhone SE, that is 103pt into a
    ///   145pt card, and 154pt of the page below it has no counterpart at all.
    /// * **Whole caption** — the caption matches AND the metric line matches
    ///   (the page's caption row borrows this cell's own constants, so the two
    ///   are the same layout at the same offsets — measured, a 101pt row
    ///   against a 101pt anchor). They part below the card's own bottom, where
    ///   the page keeps going into its comments.
    ///
    /// Answering `nil` for the second case is what this used to do, and it left
    /// a short post's comments on screen for the whole flight only to have them
    /// vanish in the final frame. There is no post for which the page and the
    /// card agree all the way down: the page always has a comment stream.
    ///
    /// MEASURED, never read off a subview's frame — see the note in
    /// `captionEnd` below, and `CaptionTruncationTests`.
    public var revealCut: CGFloat? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // PAGE-relative, not card-relative, and the distinction matters now
        // that a card can carry a band the page has no counterpart for. The
        // veil is hung at `anchor.minY + cut` inside the DESTINATION, whose
        // caption sits at `captionTopInset` from its row's top — so the cut is
        // measured from where the caption starts, never from the card's edge.
        //
        // The whole caption is shown: the difference starts below everything
        // the card has, which is its height less the band above the caption.
        guard showMoreRange != nil || isFixedCaptionCut else { return bounds.height - revealCaptionTop }
        return captionEnd
    }

    /// Whether a FIXED-height card's caption is cut short by its line cap
    /// (`fixedCaptionLines`) — the label's own ellipsis, which leaves no
    /// "Show more" range to say so.
    private var isFixedCaptionCut: Bool {
        guard let cap = fixedCaptionLines, !isCaptionExpanded else { return false }
        let available = bounds.width - Self.captionInset * 2
        guard available > 0 else { return false }
        return Self.lineCount(Self.plain(fullCaption, font: captionLabel.font), width: available) > cap
    }

    /// How far below this card's top its CAPTION begins.
    ///
    /// Zero without an author band, and the band plus its gap with one. It is
    /// the number a reveal needs in order to depart from the whole card while
    /// still landing its caption on the card's own.
    ///
    /// The first attempt avoided needing it: the flight departed from below the
    /// band instead, which kept the caption at `captionTopInset` inside the
    /// window at both ends and left the registration untouched. The frames
    /// killed it. A window that stops short of the card's top edge leaves the
    /// band outside the transition entirely, so the card gains it in one frame
    /// at the landing — a cut exactly where this transition is supposed to be
    /// seamless. The window has to be the card, and the offset has to be
    /// carried instead of avoided.
    public var revealCaptionTop: CGFloat {
        authorBand.captionOffset
    }

    /// The caption's own height plus the inset above it, in the register the
    /// DESTINATION uses — which is why it does not include the author band.
    ///
    /// MEASURED, never read off the label's frame, and that distinction is the
    /// whole of this property.
    ///
    /// A self-sizing cell gets its height from the collection view's
    /// attributes, but its subtree keeps the geometry of whatever pass last ran
    /// over it. Arm a reveal in that window and they disagree in a way that
    /// looks like nothing is wrong: measured on an iPhone SE, `bounds` was a
    /// correct 343x145 while the card underneath was still 343x88 and the label
    /// inside it 311x30 — for text that measures 86.5. `setNeedsLayout` +
    /// `layoutIfNeeded` did NOT reconcile them.
    ///
    /// The veil built on 46pt instead of 103 cut the page three lines too high,
    /// so the flight carried a greyed slab where the card's own four lines
    /// belonged. So the two inputs here are the ones that are always right:
    /// `bounds`, which comes from the attributes, and the label's own opinion
    /// of its text. `ceil` for the reason `preferredLayoutAttributesFitting`
    /// ceils — half a point short is a clipped descender.
    private var captionEnd: CGFloat? {
        let available = bounds.width - Self.captionInset * 2
        guard available > 0 else { return nil }
        let text = captionLabel.sizeThatFits(
            CGSize(width: available, height: .greatestFiniteMagnitude)
        )
        // A voice post's caption starts under its voice (#2208).
        return Self.captionTopInset + voiceBlockHeight + ceil(text.height)
    }

    /// The preview's rect in this cell's own space, or nil for a text-only row    /// The preview's rect in this cell's own space, or nil for a text-only row
    /// (which has no media to fly). A hero source reads this to decide whether
    /// a row can host a flight at all.
    public var mediaHeroRect: CGRect? {
        guard !mediaView.isHidden else { return nil }
        layoutIfNeeded()
        // A collection departs from the PAGE, not the box. The box also holds
        // the carousel's other items, whole or cropped, so a flight that took
        // it would carry several images and land one.
        if let carousel, !carousel.isHidden,
           let page = carousel.currentPageRect(in: self) {
            return page
        }
        return mediaView.frame
    }

    /// The view the media is drawn in — a collection's page on screen — nil
    /// for a text-only row: what a native preview lifts, the media alone and
    /// not the card around it (#1377). `mediaHeroRect` is its rect.
    public var mediaPreviewView: UIView? {
        guard !mediaView.isHidden else { return nil }
        if let carousel, !carousel.isHidden, let page = carousel.currentPageView { return page }
        return mediaView
    }

    /// The image the preview is currently showing — the exact pixels the
    /// viewer is looking at, so a flight starts from them rather than from a
    /// cache lookup that could miss.
    ///
    /// For a collection that is the page the viewer has scrolled to, not the
    /// post's first attachment: once they have swiped, the first attachment is
    /// no longer what they are looking at.
    public var renderedCover: UIImage? {
        if let carousel, !carousel.isHidden { return carousel.renderedCover }
        return cover.image
    }

    /// The preview box — a row's media is one part of its card, so this is the
    /// part visibility is measured against. Falls back to the whole cell only
    /// for a text row, which has no video to measure anyway.
    public var videoMediaRect: CGRect {
        // ⚠️ THE PAGE, not the box, once a collection is showing.
        //
        // The box is wider than a page and holds other items of the strip,
        // each a different attachment. Measuring it asks "is the viewer looking at
        // this preview" where the question is "at this video" — and on a mixed
        // carousel those differ by a whole page.
        if showsCarousel, let page = carousel?.currentPageRect(in: self) { return page }
        return mediaHeroRect ?? bounds
    }

    /// True while this row is drawing its collection rather than a single
    /// preview. Asked in several places, and each of them was a `!(x?.y ?? true)`
    /// before, which is one negation too many to read at a glance.
    @objc private func handleMediaHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onMediaHoldChanged?(true)
        case .ended, .cancelled, .failed:
            // ⚠️ `.cancelled` is the COMMON case, not an edge one: it fires when
            // a finger rests and then drags to page or to scroll. Treating it as
            // anything but "the hold is over" leaves the clip paused for good
            // after an ordinary swipe.
            onMediaHoldChanged?(false)
        default:
            break
        }
    }

    /// Whether this row is drawing a COLLECTION rather than one attachment.
    ///
    /// Public because the question "is this row on its clip's page" only means
    /// anything for a collection — a single attachment is always on its own —
    /// and the caller that decides whether a row should be advancing has to be
    /// able to tell the two apart. It could not, and every single-video row in
    /// the feed was declared paused as a result.
    public var showsCarousel: Bool { !(carousel?.isHidden ?? true) }

    /// The stream the CURRENT page carries, nil when the page is a still.
    ///
    /// ⚠️ The reason a caller must not use `GalleryPost.videoURL` for this: that
    /// answers for page one for ever, and a mixed collection's answer changes as
    /// the viewer scrolls. A row with a photograph on page one and a clip on
    /// page two is a `.photo` post whose current page plays.
    public var currentPageVideoURL: URL? {
        showsCarousel ? carousel?.currentPageVideoURL : nil
    }

    /// The clip this row is holding a player for, whether or not the viewer is
    /// on its page.
    ///
    /// ⚠️ What the POOL is asked about, where `currentPageVideoURL` is what
    /// decides whether it advances. A row that answered only for its current
    /// page would drop out of the ranking the moment the viewer paged onto a
    /// photograph — the slot would go, the player with it, and the paused frame
    /// would be replaced by the thumbnail this exists to keep off screen.
    public var retainedVideoURL: URL? {
        currentPageVideoURL ?? (loadedVideoRenderView == nil ? nil : hostedPageVideoURL)
    }

    /// The clip belonging to the page the surface is actually hanging in.
    private var hostedPageVideoURL: URL? {
        guard let carousel, let surface = loadedVideoRenderView else { return nil }
        return carousel.videoURL(ofPageHosting: surface)
    }

    /// The viewer moved this row's carousel. Reported OUT because what has to
    /// happen next — reconciling autoplay against a page that may or may not be
    /// a video — is the surface's business, not the cell's.
    public var onMediaPageChanged: ((Int) -> Void)?

    /// A finger is resting on this row's media (`true`), or has lifted
    /// (`false`). Relayed from the carousel, or from the preview itself for a
    /// single attachment — the gesture is the same on both, and so is what it
    /// means.
    public var onMediaHoldChanged: ((Bool) -> Void)?

    // MARK: - The autoplay surface: the video render view a row hosts — state here, behaviour in `PostGridListRowCell+Autoplay.swift`
    public var loadedVideoRenderView: VideoRenderView?


    // MARK: - Retained clips: the surfaces a row keeps, prewarms, adopts and donates — state here, behaviour in `PostGridListRowCell+RetainedClips.swift`
    /// A surface per clip page this row is keeping warm, keyed by page.
    ///
    /// ⚠️ THE ROW'S BUDGET IS WHAT IS LEFT OVER, not the pool's whole capacity.
    ///
    /// A post open full-screen is the only thing drawing and may spend the lot.
    /// A row is one of several on screen, and the coordinator hands every chosen
    /// row a player before anything is kept warm — so a row helping itself to
    /// the same window would starve its neighbours, which is precisely the
    /// budget `maxConcurrent` exists to divide. `retainClips(budget:)` is told
    /// how much is spare; when the answer is nothing, this holds one entry and
    /// the row behaves as it always did.
    var pageSurfaces: [Int: VideoRenderView] = [:]
    /// How many EXTRA clips this row has been allowed to keep. Zero until a
    /// coordinator says otherwise, which is what makes the retention opt-in
    /// rather than something a row helps itself to.
    var clipBudget = 0
    /// Fired when the cover lands from an async load, so the autoplay gate is
    /// re-run for a row that arrived faceless.
    public var onCoverLoaded: (() -> Void)?
    /// Called when the collection view recycles this row, so the coordinator
    /// takes its player back before the cell is bound to another post.
    public var onReuse: (() -> Void)?

    /// Decides whether the caption OVERFLOWS, at the width the layout is
    /// actually going to give this row.
    ///
    /// It cannot be decided in `configure`: a self-sizing cell is configured
    /// before it is sized, so the width there is whatever the recycled cell
    /// happened to be carrying, and a caption measured against the wrong width
    /// answers the wrong question — three lines at one width is five at
    /// another. The attributes are authoritative, which is the same reason
    /// `CaptionBubbleCell` measures here rather than there.
    ///
    /// The measurement is the honest one: how tall the caption WANTS to be
    /// against how tall the cap allows. Asking `UILabel` whether it truncated
    /// would be reading a result of the layout pass that is being computed.
    override public func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let targetWidth = layoutAttributes.frame.width
        guard targetWidth > 0 else {
            return super.preferredLayoutAttributesFitting(layoutAttributes)
        }
        if abs(bounds.width - targetWidth) > 0.5 {
            bounds.size.width = targetWidth
        }
        composeCaption(atWidth: targetWidth)
        // The preview's height is a function of the row's width, so it belongs
        // in the same pass and for the same reason: `configure` runs before the
        // cell is sized, and a height resolved against a recycled cell's old
        // width is the wrong height.
        resolveMediaHeight(atWidth: targetWidth)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        let fitted = contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        // Ceil, not round: half a point short of the caption is a clipped
        // descender on the last line.
        layoutAttributes.frame.size.height = ceil(fitted.height)
        return layoutAttributes
    }

    // MARK: - The caption: measured at the layout's width, truncated with its Show more — state here, behaviour in `PostGridListRowCell+Caption.swift`
    /// Fired when the viewer taps the media of a COLLECTION row.
    ///
    /// A row with one photograph needs nothing here — the collection view's own
    /// selection handles it. A carousel is a scroll view, and a scroll view in
    /// the content path swallows that selection, so the host has to be told
    /// separately. See `MediaCarouselView.onTapped`.
    public var onMediaTapped: (() -> Void)?
    /// Fired when the viewer taps the COMMENT COUNT, on either card shape.
    ///
    /// ⚠️ A different destination from the row's own tap, not a shortcut to it.
    /// Tapping the card opens the post; tapping this opens the post AT ITS
    /// COMMENTS. The count is the only thing on the card that names the thread,
    /// so it is the only place the shorter route belongs — and a viewer who
    /// wanted the photograph has the whole rest of the card to press.
    ///
    /// Wired on BOTH the media overlay's chip and the closing line's, because
    /// which one a post wears depends on whether it happens to carry a
    /// photograph, and an affordance that comes and goes with that is not one.
    public var onCommentsTapped: (() -> Void)?

    // MARK: - The hero flight: what hides while a twin is in the air, and the furniture's return — state here, behaviour in `PostGridListRowCell+Hero.swift`
    /// Whether a flight is currently standing in for this row's media.
    /// Readable so a caller can assert the END STATE of a transition rather
    /// than the calls that were supposed to produce it. A row whose media is
    /// still standing in for a flight that ended is the shipped defect this
    /// answers — and it is invisible to every test that only counts hides.
    public var isHeroMediaConcealed = false

    // MARK: - The card's shape and the preview's height, measured without a cell — state here, behaviour in `PostGridListRowCell+Sizing.swift`
    /// The caption's cap on a card of a FIXED height — nil on every card the
    /// list sizes to its content (the default).
    ///
    /// For You's Following section lays its text cards in a row of one height
    /// (`PostShelfRows`), so a card there can neither grow by a "Show
    /// more" nor shrink with a short caption: the caption is held to this
    /// many lines and the LABEL cuts the rest with an ellipsis — no
    /// affordance, the whole card opens the post — and the closing line
    /// stands at the card's foot whatever the caption's length, a one-line
    /// caption leaving its air above the line rather than under it.
    public private(set) var fixedCaptionLines: Int?
    /// Fired when the viewer asks for the rest of a truncated caption. The HOST
    /// owns the answer, not this cell: a cell is recycled and the expansion has
    /// to survive that, so the set of expanded posts lives in
    /// `CaptionExpansion` and comes back through `configure`.
    public var onRevealFullCaption: (() -> Void)?

    // MARK: - The author band, the row's actions, the stake and the counts — state here, behaviour in `PostGridListRowCell+Actions.swift`
    /// The closing row's repost control. Nil HIDES it — visibility tracks the
    /// answer, not the presence of a provider, the same rule the "..." follows.
    public var onRepostTapped: (() -> Void)? {
        didSet {
            repostAction.isHidden = onRepostTapped == nil
            syncClosingLine()
        }
    }
    /// The closing row's save control. Nil hides it.
    public var onBookmarkTapped: (() -> Void)? {
        didSet {
            bookmarkAction.isHidden = onBookmarkTapped == nil
            syncClosingLine()
        }
    }
    /// The like chip's STAKE — a tap spends the default amount through this,
    /// a menu pick spends its amount. Nil leaves the chip a counter.
    ///
    /// Likes and points are one thing (the A/B economy, charter V5.3): liking
    /// a post IS staking on it, so the chip that counts likes is the chip
    /// that spends. The cell never touches a wallet — it reports amounts and
    /// renders what the host answers (`setViewerStake`,
    /// `playStakeConfirmation`, `playStakeDenied`).
    public var onStake: ((Int) -> Void)? {
        didSet { applyStakeWiring() }
    }
    /// The menu a held like chip raises (`StakeMenu`), built when raised.
    public var stakeMenu: (() -> UIMenu?)? {
        didSet { likesAction.menuProvider = stakeMenu }
    }
    /// The amount a plain tap on the like chip stakes. Set with `onStake`.
    public var stakeTapAmount = WalletStore.Policy.defaultStakeAmount
    var baseReactionCount: Int64?
    var viewerStake = 0
    /// What `configure` drew — `postLikeCount`, `showLikeCount`.
    var configuredReactionCount: Int64?
    /// Whether this post is saved. Set by the host from whatever owns the pile;
    /// the control never decides for itself.
    public var isBookmarked: Bool = false {
        didSet { applyBookmarkGlyph() }
    }

    /// Makes this cell show `text` as its age.
    public func overrideAgeText(_ text: String) {
        // The age alone — the band keeps the picture it already has.
        authorBand.setAge(text)
        closingAgeLabel.text = text
    }

    /// Whether the author band is drawing a picture rather than initials —
    /// for tests.
    var authorBandShowsPicture: Bool { authorBand.isShowingPicture }

    let card = UIView()
    /// The author band — shown only where the row's post actually carries an
    /// identity.
    ///
    /// A profile gallery's posts do not: that surface is already scoped to one
    /// author, so `GalleryPost`'s author fields are left nil there and the band
    /// disappears without anyone passing a flag. The band is therefore a
    /// function of the DATA rather than of the screen, which is the only
    /// version of this that cannot be wired up wrong.
    ///
    /// The VIEW is shared with the reveal's transition prop — see
    /// `PostAuthorBandView` for why that matters.
    let authorBand = PostAuthorBandView()
    /// The band's trailing end: on the caption's column on a card, hung out
    /// by the "..."'s air on a row (#2289) — see `bandTrailingInset`.
    private var bandTrailing: NSLayoutConstraint!
    /// The author the band was last configured for — whose mark it wears.
    private var bandAuthorID: ProfileID?
    /// The caption hangs off the band — at the band's gap when the band draws
    /// something, and flush when it has collapsed to nothing.
    var captionFollowsBand: NSLayoutConstraint!
    /// A voice post's caption (#2208, behind `-voice-posts`): the shared
    /// voice component where the caption starts — full on a list card, compact
    /// on a shelf's fixed card — the caption's words under it on full size.
    /// Pinned to the caption's insets, the neutral panel spans the card's
    /// content width whatever the voice's length (#2241): a short voice no
    /// longer leaves the card bare.
    let voiceCaption = VoicePostCaptionView()
    /// The voice hangs off the band as the caption does; the caption then
    /// hangs off the voice.
    var voiceFollowsBand: NSLayoutConstraint!
    var captionFollowsVoice: NSLayoutConstraint!
    /// A showcase's card (#2216, behind `-channels`): the shared embed card
    /// under the author's words — full on the list's card, compact and alone
    /// on a shelf's fixed card. Its action button takes its own tap; the rest
    /// of it is the card's, which opens the post.
    let embedCard = PostEmbedView()
    /// Whether the card shows a showcase's embed: it then draws no comment
    /// count (#2216).
    var showsShowcase = false
    /// The card hangs off the caption; while it shows, the closing line (or
    /// the card's foot) hangs off the card instead of the caption.
    var embedFollowsCaption: NSLayoutConstraint!
    var metaFollowsEmbed: NSLayoutConstraint!
    var metaStandsUnderEmbed: NSLayoutConstraint!
    var embedClosesCard: NSLayoutConstraint!
    /// Emoji and `:code:` emotes animate in the caption (`plain` marks them).
    let captionLabel = EmoteLabel()
    var isCaptionExpanded = false
    /// The caption as the post carries it. The label shows a SHORTENED version
    /// while truncated, so the label's own text is not a copy of this and
    /// cannot be used in its place.
    var fullCaption = ""
    /// The closing metric line.
    var metaRow: UIStackView!
    /// Where "Show more" sits inside the label's current attributed text, or
    /// nil when the caption fits and there is no affordance at all.
    ///
    /// It is the tap target: a range, not a view, because the affordance is a
    /// run of glyphs inside the caption's own layout now — see
    /// `captionTapped`.
    var showMoreRange: NSRange?
    let mediaView = UIImageView()
    private static let metaFont = UIFont.appFont(forTextStyle: .footnote)
    /// The closing line's counters — the card's PRIMARY actions, ranked by
    /// carrying a count and holding the line's end rather than by a darker
    /// ink: glyph and count in the line's one ink (`PostCardPillView.ink`).
    /// The app's one button since #934 (`PostCardAction`).
    let likesAction: AppIconButton = {
        // Staked, the button's own filled heart in the Points pink — no
        // `LikesHeartView` laid over it (#1186): that overlay showed the like
        // twice and left a mark during the hero flight home, and the hearts
        // are solid since #1178.
        PostCardAction.make(symbol: ActionSymbol.like, label: "Likes", selectedTint: LikesSymbol.tint)
    }()
    let commentsAction = PostCardAction.make(symbol: ActionSymbol.comments, label: "Comments")
    /// Whether the likes keep their heart with no count: a staking card's
    /// like is a door even before the post has a number.
    var likesKeepsGlyph = false
    /// The post the row is bound to.
    private var boundPostID: PostID?
    /// Whether the actions animate a change: off from `configure` until the
    /// next turn of the run loop, so the host's first answers for a newly
    /// bound post (its stake, its saved state, set right after `configure`)
    /// land as they are; a change after that is news and moves (#934).
    var actionsAnimate = false

    /// The closing row's date — drawn only when the band above is BARE, so a
    /// profile's own cards still say when. On a card with an identity the
    /// date is on the handle's line instead.
    private let closingAgeLabel = UILabel()
    /// The closing row's two SECONDARY actions, each its own plain control,
    /// leading the line: `[save][repost][pages] ······ [comments][likes]`. One
    /// control per verb, so a hidden one closes its own slot.
    let repostAction = PostCardAction.make(symbol: ActionSymbol.repost, label: "Repost")
    /// Saved, the star is the full-screen post's gold — the reference, the
    /// owner's call (#1182, #1188): one gold in both appearances.
    let bookmarkAction = PostCardAction.make(symbol: ActionSymbol.save, label: "Save", selectedTint: SaveStar.tint)

    /// The preview wears ONE piece of furniture, the page indicator: what the
    /// viewer can press about a post lives in the closing row under the
    /// preview, not on the photograph, so the picture stays the star.
    /// Which page of a collection is showing. Always built — it is a chip in the
    /// same row as the other two and hides itself for a single-media post.
    private let pageIndicator = MediaPageIndicatorView()
    /// Built on first use: most posts have one piece of media.
    var carousel: MediaCarouselView?

    /// The carousel, for a test that needs to ask where a page put something.
    var debugCarousel: MediaCarouselView? { carousel }

    /// The single-media cover on the loading ladder (#1088): a reconfigure
    /// for another post cancelling the load in flight (#781), a parked frame
    /// outranking a late thumbnail, every new cover the live surface's poster.
    /// Only the cover half of `MediaSurface`: the row's surfaces are per page
    /// and hang in the box behind its furniture, which is the row's own
    /// plumbing. Readable inside the package so a test can ask what is in
    /// flight.
    private(set) lazy var cover: CoverSlot = {
        let cover = CoverSlot(view: mediaView, size: .full)
        // The row now has a face, which is the one thing the autoplay gate
        // was waiting for. Nothing else would ask again while the timeline
        // sits still.
        cover.onLoaded = { [weak self] in self?.onCoverLoaded?() }
        cover.onChange = { [weak self] image in self?.loadedVideoRenderView?.setPoster(image) }
        return cover
    }()
    /// The metadata line always hangs off the caption; what changes per
    /// configure is whether it CLOSES the card. A media row's line is hidden
    /// under the preview, laid out but drawing nothing, which is what keeps it
    /// out of the height without leaving it unconstrained.
    /// The preview's height, which is the post's OWN aspect ratio clamped —
    /// see `mediaHeight(forCardWidth:aspectRatio:)`. Held so a width change can
    /// re-resolve it.
    lazy var mediaHeight: NSLayoutConstraint =
        mediaView.heightAnchor.constraint(equalToConstant: 0)
    /// The aspect the current post declares, kept because the height depends on
    /// a width this cell does not know until it is measured.
    var mediaAspectRatio: Double = 1
    /// How many pages the current post's media has — more than one, and the
    /// height is the carousel's (`collectionMediaHeight`), not the aspect's.
    var mediaPageCount = 1

    private var metaFollowsCaption: NSLayoutConstraint!
    /// A FIXED-height card's version of `metaFollowsCaption`: the line at least
    /// a gap under the caption, held at the card's foot by `metaClosesCard` —
    /// see `fixedCaptionLines`.
    private var metaStandsUnderCaption: NSLayoutConstraint!
    /// Active for media rows only: the closing row hangs off the preview.
    private var metaFollowsMedia: NSLayoutConstraint!
    /// The closers a card uses when its closing line has NOTHING on it — no
    /// count, nothing wired, no date to show: the caption or the preview then
    /// closes the card at the content inset, and the line is not paid for.
    private var captionClosesCard: NSLayoutConstraint!
    private var mediaClosesCard: NSLayoutConstraint!
    /// The give in the closing line, kept so the line can tell whether it is
    /// showing anything but this.
    private let lineSpacer = UIView()
    /// Active for text rows only: the line is the card's last thing. A media
    /// row ends at the preview instead — see `mediaClosesCard`.
    private var metaClosesCard: NSLayoutConstraint!
    /// The line's two ends, hung by `syncClosingLine` — see `closingLineHang`.
    private var metaLeading: NSLayoutConstraint!
    private var metaTrailing: NSLayoutConstraint!
    private var mediaConstraints: [NSLayoutConstraint] = []

    override public init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerCurve = .continuous
        // A shelf's card: its tone, corner and edge — an edge in the dark and
        // nothing in the light, see `Surface` — or none of them on a list's
        // row (#2243): `applyDress`, re-run on a style flip.
        applyDress()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (cell: PostGridListRowCell, _: UITraitCollection) in
            cell.applyDress()
        }
        buildRowChrome()
        card.pin(to: contentView)

        captionLabel.font = .appFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        // A `@handle` in the caption opens its profile (#524).
        captionLabel.opensTextEntities = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = Self.captionLineLimit
        // WORD WRAPPING, not tail truncation, and that is not a detail: the
        // ellipsis is written into the text here rather than drawn by the
        // label, because it has to be followed by "Show more" ON THE SAME
        // LINE. A label that truncates for itself puts the ellipsis at the
        // very end of the last line and leaves nowhere to put anything after
        // it.
        captionLabel.lineBreakMode = .byWordWrapping
        // TOP-ANCHORED DRAWING, and this is what makes the expansion read as a
        // reveal rather than as a jump.
        //
        // A label centres its text block inside its own bounds. Expanding sets
        // the whole caption on a label whose frame is still four lines tall and
        // then animates that frame open — so for the length of the animation
        // the text is taller than the box holding it, and centred means the
        // lines already on screen slide UP and out before drifting back down.
        // Anchored to the top they simply stay where they are while the rest
        // arrives underneath.
        captionLabel.contentMode = .top
        // The affordance is a run of glyphs inside this label, so the label is
        // what receives its tap.
        captionLabel.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(captionTapped))
        tap.delegate = self
        captionLabel.addGestureRecognizer(tap)
        buildAuthorBand()

        captionLabel.constrain(in: card) { parent in
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Self.captionInset)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Self.captionInset)
        }
        captionFollowsBand = captionLabel.topAnchor.constraint(
            equalTo: authorBand.bottomAnchor, constant: Self.authorFollowGap
        )
        captionFollowsBand.isActive = true
        buildVoiceCaption()
        authorBand.onShapeChange = { [weak self] in self?.syncCaptionToBand() }

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        // ⚠️ `UIImageView` ships with interaction OFF, and everything inside the
        // preview inherits that: the carousel's scroll view was unhittable, so a
        // swipe on the pages reached the tab pager instead and changed tab.
        //
        // It survived a unit test on the pager's yielding rule AND the fix to
        // that rule, because the rule asks what is under the touch — and with
        // the box refusing hits, what was under the touch was the card. One
        // default, two symptoms, and only a real drag on the simulator found it.
        mediaView.isUserInteractionEnabled = true
        // CONCENTRIC with the card, not a constant of its own: the preview is
        // inset from the card's edge, and a curve parallel to the one around it
        // is the inner radius reduced by exactly that inset. It was 12 against
        // an 18pt card, which was parallel to nothing.
        mediaView.layer.cornerRadius = Self.mediaCornerRadius
        mediaView.layer.cornerCurve = .continuous
        card.addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false

        // ⚠️ HOLD TO PAUSE LIVES ON THE MEDIA, NOT ON THE CAROUSEL.
        //
        // A post with one attachment is a gallery of one — the gesture means the
        // same thing on both and there is no reason for two implementations to
        // drift apart. It sat on the carousel first, which gave the behaviour to
        // collections only and left single-video cards without it.
        //
        // On `mediaView`, an ancestor of the carousel, so the pages still
        // receive the pan.
        //
        // ⚠️ IT MUST CANCEL THE TOUCH, and this is where the two shapes were not
        // really unified. A collection opens by its carousel's own tap; a single
        // attachment opens by the COLLECTION VIEW selecting the cell, which is
        // driven by plain touch delivery. Letting the touch through therefore
        // opened the post the moment a hold ended — on single-media cards only,
        // which is exactly how it was reported.
        //
        // Cancelling costs the pans nothing: a gesture recognizer is not touch
        // delivery, so the carousel still pages and the feed still scrolls. What
        // it stops is the cell's own selection tracking — and only once the hold
        // has actually recognised, so an ordinary tap still opens the post.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleMediaHold))
        hold.minimumPressDuration = MediaCarouselView.holdToPauseDuration
        hold.cancelsTouchesInView = true
        mediaView.addGestureRecognizer(hold)

        let spacer = lineSpacer
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        // ⚠️ ONE CLOSING ROW, ON EVERY CARD, and it is where every control is.
        //
        //     [save][repost][2h][pages] ·······  [comments][likes]
        //
        // What the viewer DOES leads the line and what the post HAS closes
        // it. The counters used to sit on a media card's photograph and under
        // a text card's caption, and the repost and save controls sat in the
        // header beside the name — two clusters of controls per card, and a
        // different one depending on whether the post carried a picture. Now
        // the header says who and when, the picture is a picture, and this
        // row is the one place a finger goes. It closes the card whatever the
        // card holds: under the caption of a text post, under the preview of
        // a media post.
        //
        // The date joins the leading group only on a card whose band is bare
        // (a profile's own), and the page indicator only on a collection. Of
        // everything on the line the INDICATOR is what gives way first when
        // the width runs out — a shorter run of dots still says "there is
        // more" — and a count never truncates: a clipped count is a wrong
        // count.
        //
        // Card actions, not media pills: PLAIN, ink on the card's own fill
        // (no capsule since 2026-09-30 — see `PostCardPillView`). Comments
        // and likes are the primary pair, repost and save the secondary one.
        likesAction.addAction(UIAction { [weak self] _ in
            guard let self, let onStake else { return }
            onStake(stakeTapAmount)
        }, for: .primaryActionTriggered)
        likesAction.isUserInteractionEnabled = false
        likesAction.isHidden = true
        commentsAction.addAction(UIAction { [weak self] _ in self?.onCommentsTapped?() }, for: .primaryActionTriggered)
        commentsAction.isHidden = true
        repostAction.addAction(UIAction { [weak self] _ in self?.onRepostTapped?() }, for: .primaryActionTriggered)
        bookmarkAction.addAction(UIAction { [weak self] _ in self?.onBookmarkTapped?() }, for: .primaryActionTriggered)
        bookmarkAction.isToggle = true
        repostAction.isHidden = true
        bookmarkAction.isHidden = true
        closingAgeLabel.font = .appFont(forTextStyle: .footnote)
        closingAgeLabel.adjustsFontForContentSizeCategory = true
        closingAgeLabel.textColor = .secondaryLabel
        closingAgeLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        closingAgeLabel.isHidden = true
        // A pill tall, like everything else on the line, and the first thing
        // to yield: below the counts' 999 and above its own two-dot floor.
        pageIndicator.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        pageIndicator.setContentHuggingPriority(.required, for: .horizontal)
        let dotFloor = pageIndicator.widthAnchor.constraint(
            greaterThanOrEqualToConstant: pageIndicator.minimumChipWidth
        )
        dotFloor.priority = UILayoutPriority(749)
        let indicatorHeight = pageIndicator.heightAnchor.constraint(equalToConstant: PostMetaPillView.height)
        indicatorHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([dotFloor, indicatorHeight])
        pageIndicator.isHidden = true
        let metaRow = UIStackView(
            arrangedSubviews: [
                bookmarkAction, repostAction, closingAgeLabel, pageIndicator,
                spacer, commentsAction, likesAction
            ]
        )
        self.metaRow = metaRow
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        // The chips' own gap: capsules side by side belong together more
        // closely than a run of loose labels did. The spacer takes up
        // everything else — and the gap either side of it is the spacer's
        // own, so a line with nothing leading it still ends at the counters.
        metaRow.spacing = Self.chipGap
        // The ends HANG: `syncClosingLine` moves them out by the ink inset
        // of whatever box opens and closes the line, so the ink sits on the
        // line's own column (`closingLineInset(for:)`, the dress's). Written
        // at that inset here, which is right for a line whose ends have no
        // air of their own (the date, the indicator's capsule).
        let metaLeading = metaRow.leadingAnchor.constraint(
            equalTo: card.leadingAnchor, constant: Self.closingLineInset(for: dress)
        )
        let metaTrailing = metaRow.trailingAnchor.constraint(
            equalTo: card.trailingAnchor, constant: -Self.closingLineInset(for: dress)
        )
        self.metaLeading = metaLeading
        self.metaTrailing = metaTrailing
        metaRow.constrain(in: card) { _ in
            metaLeading
            metaTrailing
            // A pill tall whatever is on it: a line holding only the date is
            // the same line as one holding capsules, and the card under it
            // the same height.
            metaRow.heightAnchor.constraint(equalToConstant: PostMetaPillView.height)
        }
        captionClosesCard = captionLabel.bottomAnchor.constraint(
            equalTo: card.bottomAnchor, constant: -Self.contentInset
        )
        mediaClosesCard = mediaView.bottomAnchor.constraint(
            equalTo: card.bottomAnchor, constant: -Self.mediaInset
        )
        metaFollowsCaption = metaRow.topAnchor.constraint(
            equalTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
        )
        metaFollowsCaption.isActive = true
        metaStandsUnderCaption = metaRow.topAnchor.constraint(
            greaterThanOrEqualTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
        )
        metaFollowsMedia = metaRow.topAnchor.constraint(
            equalTo: mediaView.bottomAnchor, constant: Self.captionFollowGap
        )
        metaClosesCard = metaRow.bottomAnchor.constraint(
            equalTo: card.bottomAnchor, constant: -Self.metaBottomInset
        )
        metaClosesCard.isActive = true
        mediaConstraints = [
            mediaView.topAnchor.constraint(
                equalTo: captionLabel.bottomAnchor, constant: Self.captionFollowGap
            ),
            mediaView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.mediaInset),
            mediaView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.mediaInset),
            mediaHeight
        ]
        buildEmbedCard()
    }

    /// Whether the closing line shows anything at all, and the card's closer
    /// with it. Asked after every change to what is on the line — a
    /// configure, a control wired or unwired, scenery drawn — because a line
    /// with nothing on it is not drawn and not paid for: the caption or the
    /// preview closes the card instead.
    func syncClosingLine() {
        let hasMedia = !mediaView.isHidden
        let isEmpty = metaRow.arrangedSubviews.allSatisfy { $0.isHidden || $0 === lineSpacer }
        metaRow.isHidden = isEmpty
        // The line keeps hanging off the caption or the preview either way —
        // hidden, it draws nothing, and an unconstrained hidden view is an
        // ambiguity for nothing.
        let isFixed = fixedCaptionLines != nil
        // A showcase's card (#2216) stands between the words and the line: a
        // text post's foot is the card's then, not the caption's.
        let hasEmbed = !embedCard.isHidden && !hasMedia
        let textFoot = !hasMedia && !hasEmbed
        metaFollowsCaption.isActive = textFoot && !isFixed
        metaStandsUnderCaption.isActive = textFoot && isFixed
        metaFollowsEmbed.isActive = hasEmbed && !isFixed
        metaStandsUnderEmbed.isActive = hasEmbed && isFixed
        metaFollowsMedia.isActive = hasMedia
        metaClosesCard.isActive = !isEmpty
        captionClosesCard.isActive = isEmpty && textFoot
        embedClosesCard.isActive = isEmpty && hasEmbed
        mediaClosesCard.isActive = isEmpty && hasMedia
        hangLineEnds()
    }

    /// Hangs the closing line's two ends off this dress's column
    /// (`closingLineInset(for:)`) by the air their boxes leave before the
    /// ink, and the band's "..." the same way (`bandTrailingInset(for:)`).
    /// Re-run on a dress change, since the column is the dress's.
    private func hangLineEnds() {
        if let bandTrailing {
            bandTrailing.constant = -Self.bandTrailingInset(for: dress)
        }
        guard let metaLeading, let metaTrailing else { return }
        let column = Self.closingLineInset(for: dress)
        let hang = closingLineHang
        metaLeading.constant = column - hang.leading
        metaTrailing.constant = -(column - hang.trailing)
    }

    /// The closing line's column for a dress: where its first ink starts and
    /// its last ink ends, from the cell's edges.
    ///
    /// * **A card** (a shelf's): `actionLineInset`, one plain padding inside
    ///   the caption's — the card's sides are what the line was held off
    ///   (2026-09-30).
    /// * **A row** (#2289): the caption's own column. A row has no side to
    ///   press against, and the card's 8 extra points stood everything on the
    ///   right 8pt further in than everything on the left — the owner read
    ///   the post as pushed left. On a row, every ink stands on one column,
    ///   16pt from the screen on both sides (`PostGridListLayout.rowInset` +
    ///   `captionInset`); a press's capsule spills about 8pt into the margin,
    ///   which is fine on a page with no card edge.
    public static func closingLineInset(for dress: Dress) -> CGFloat {
        dress == .row ? captionInset : actionLineInset
    }

    /// The band's trailing inset for a dress, from the cell's trailing edge.
    ///
    /// * **A card**: the caption's column — the "..." control's BOX ends
    ///   there, its glyph its air further in, over the closing line's last
    ///   count (both on `actionLineInset`).
    /// * **A row** (#2289): hung out by the "..."'s air
    ///   (`PostAuthorBandView.menuInkTrailing`), so its INK ends on the
    ///   caption's column, over the closing line's last count — which a row
    ///   also ends there.
    public static func bandTrailingInset(for dress: Dress) -> CGFloat {
        dress == .row ? captionInset - PostAuthorBandView.menuInkTrailing : captionInset
    }

    /// How far the closing line's two ends reach past the line's column
    /// (`closingLineInset(for:)`).
    ///
    /// ⚠️ THE INK IS ON THE COLUMN, NOT THE BOX. A plain action still has a
    /// box — the press region, and the capsule the press wash draws — but
    /// nothing marks its edge, so a box standing on the column put the save
    /// glyph a few points further in than the like count's end — the two
    /// ends of one line at two different insets. Each end hangs out by the
    /// air its own box leaves before the ink; the date and the indicator's
    /// capsule have none, and hang nothing.
    ///
    /// On a card the column is one plain padding inside the caption's, so the
    /// widest hang (the save glyph's ~8pt) puts that box back on the
    /// caption's column — never past it. On a row the column IS the
    /// caption's, and the box spills that hang into the margin (#2289).
    var closingLineHang: (leading: CGFloat, trailing: CGFloat) {
        let shown = metaRow.arrangedSubviews.filter { !$0.isHidden && $0 !== lineSpacer }
        return (
            (shown.first as? AppIconButton).map(PostCardAction.inkLeading) ?? 0,
            (shown.last as? AppIconButton).map(PostCardAction.inkTrailing) ?? 0
        )
    }

    /// The carousel, built on first use — most posts have one piece of media and
    /// should not pay for a scroll view they will never scroll.
    ///
    /// Inserted BELOW the chips, and that is the layout's whole contract with
    /// them: the chips and the indicator belong to the PREVIEW, not to what is
    /// inside it. They are pinned to the box, the pages move underneath, and
    /// nothing about a drag can shift them. Putting them inside the scroll view
    /// would have been the natural way to write this and would have carried the
    /// counters off the screen with page two.
    private func makeCarouselIfNeeded() -> MediaCarouselView {
        if let carousel { return carousel }
        let view = MediaCarouselView()
        view.onPageChanged = { [weak self] page in
            guard let self else { return }
            self.pageIndicator.setCurrent(page)
            // ⚠️ The surface STAYS on its page. It used to be evicted here.
            //
            // Evicting put the page's thumbnail back the moment the viewer moved
            // on, and in a carousel that page is still on screen — so a clip
            // appeared to be replaced by a photograph while it was merely no
            // longer the one being watched. It is paused in place instead, and
            // keeps its last frame.
            //
            // Moving it is still handled: `install` re-hosts it when the viewer
            // arrives at a DIFFERENT clip, and `host` clears the page it came
            // from.
            self.onMediaPageChanged?(page)
        }
        // The indicator is a control, and the cell is what connects it: neither
        // half reaches the other, which is what keeps the carousel the only
        // thing that decides where the pages are.
        pageIndicator.onPageRequested = { [weak view] page in
            // ⚠️ NOT ANIMATED. The chip is a scrubber: the viewer's finger is
            // the clock, and an animation would run its own on top — a drag
            // across twelve pages would queue twelve scroll animations and
            // arrive late at every one of them. Teleporting keeps the page under
            // the finger where the finger is.
            view?.setPage(page, animated: false)
        }
        view.onTapped = { [weak self] in self?.onMediaTapped?() }
        // ⚠️ AT THE BOTTOM, not below a NAMED chip.
        //
        // This used to go in below `likesPill` — which was the first chip added
        // and therefore the lowest, so "below the first one" and "below all of
        // them" were the same thing by accident. Reversing the row's reading
        // order made likes the LAST chip added, and the carousel went in above
        // the date and drew over it: a chip laid out correctly, in front of
        // nothing. Measured as a media row with no date on it at all.
        //
        // Index zero says what was meant, and cannot be undone by reordering
        // the chips again. The preview's cover is the image view's own content
        // rather than a subview, so nothing of the row's is below this.
        mediaView.insertSubview(view, at: 0)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: mediaView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: mediaView.trailingAnchor),
            view.topAnchor.constraint(equalTo: mediaView.topAnchor),
            view.bottomAnchor.constraint(equalTo: mediaView.bottomAnchor)
        ])
        carousel = view
        return view
    }

    private func buildAuthorBand() {
        let trailing = authorBand.trailingAnchor.constraint(
            equalTo: card.trailingAnchor, constant: -Self.bandTrailingInset(for: dress)
        )
        bandTrailing = trailing
        authorBand.constrain(in: card) { parent in
            authorBand.topAnchor.constraint(
                equalTo: parent.topAnchor, constant: Self.captionTopInset
            )
            authorBand.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor, constant: Self.captionInset
            )
            trailing
        }
    }

    private func bindAuthorBand(
        to post: GalleryPost, imagePipeline: ImagePipeline, showsIdentity: Bool
    ) {
        // The same author again keeps the mark the host drew (#2300): a
        // reconfigure is not a new person, and the binding draws a new one.
        let keepsMark = post.authorID != nil && post.authorID == bandAuthorID
        bandAuthorID = post.authorID
        let model = PostAuthorBandView.Model(post: post, showsIdentity: showsIdentity)
            .withRelationMark(keepsMark ? authorBand.relationMark : .none)
        authorBand.configure(with: model, imagePipeline: imagePipeline)
        // A bare band says nothing about WHEN; the closing line does.
        closingAgeLabel.text = model.age
        closingAgeLabel.isHidden = model.showsIdentity
    }

    /// Follows the band's shape: the caption sits a gap under a band that
    /// draws something and flush with the card's top under one that has
    /// collapsed — a profile's own post with nothing to offer in a "...".
    private func syncCaptionToBand() {
        captionFollowsBand.constant = authorBand.isCollapsed ? 0 : Self.authorFollowGap
        voiceFollowsBand.constant = captionFollowsBand.constant
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func prepareForReuse() {
        super.prepareForReuse()
        // Hand the player back BEFORE anything else: a recycled row that kept
        // its loan would show the previous post's video under the new post's
        // cover. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        endVideoPreview()
        // A selection belongs to the post it was made on.
        endCaptionSelection()
        // Concealment is per-flight state and must not ride a recycled cell to
        // whatever post it is bound to next — the row equivalent of the tile's
        // `isHidden` reset.
        //
        // BOTH channels, because the routing depends on whether a carousel is
        // showing and that answer changes with the post: a row recycled from a
        // collection to a single photo would otherwise reset only the page it no
        // longer has, and keep the preview it now uses at alpha 0.
        setHeroMediaConcealed(false)
        mediaView.alpha = 1
        // ⚠️ AND THE CARD, which is the channel a TEXT row is concealed on.
        //
        // This listed two channels and had three. A text row is concealed by
        // taking the whole card to alpha 0 — it has no preview to hide — and
        // that was the one nothing here put back. A recycled row therefore
        // arrived bound to a new post with `card.alpha` still 0: invisible, but
        // holding its slot, which is a HOLE in the feed exactly the height of a
        // card. Reported after several round trips, because each one can leave
        // another.
        card.alpha = 1
        cover.reset()
        // A recycled row must not keep the previous post's pages: the loads are
        // per-page tasks and the indicator is per-post state, and neither is
        // touched by `configure` for a post that turns out to have one piece of
        // media.
        carousel?.cancelPendingWork()
        carousel?.isHidden = true
        pageIndicator.isHidden = true
        onRevealFullCaption = nil
        // A voice it played stops: the card is another post's now (#2208).
        applyVoice(nil, for: nil)
        // So does a showcase's card, and a write in flight for it (#2216).
        applyEmbed(nil, for: nil, imagePipeline: nil)
        // Back to truncated. A recycled row must not inherit the previous
        // post's expansion — `configure` re-applies the host's answer for the
        // post it is actually bound to.
        isCaptionExpanded = false
        fixedCaptionLines = nil
        captionLabel.numberOfLines = Self.captionLineLimit
        captionLabel.lineBreakMode = .byWordWrapping
        showMoreRange = nil
        // A landing's fade is per-flight state and must not ride a recycled
        // cell to whatever post it is bound to next.
        metaRow.alpha = 1
        authorBand.cancelPendingWork()
        // Both band handlers capture the POST they were built for, so a
        // recycled row must not keep them: the "..." would offer to unfollow
        // the previous post's author, and the identity would push their
        // profile.
        onAuthorTapped = nil
        onAuthorHeld = nil
        onAuthorFollowTapped = nil
        // The previous author's mark never rides a recycled row (#2300).
        bandAuthorID = nil
        authorBand.setRelationMark(.none, animated: false)
        authorMenuActions = nil
        onMediaTapped = nil
        onCommentsTapped = nil
        // Both capture the POST they were built for, like the two above: a
        // recycled row would otherwise save someone else's post.
        onRepostTapped = nil
        onBookmarkTapped = nil
        isBookmarked = false
        // The stake captures its post too, and the viewer's stake on the
        // previous post must not tint the next one's heart.
        onStake = nil
        stakeMenu = nil
        viewerStake = 0
        // Concealment is per-FLIGHT state and must not ride a recycled cell to
        // whatever post it is bound to next — see `setHeroConcealed`.
        card.alpha = 1
        authorBand.alpha = 1
    }

    // MARK: - The dress: a list's row, or a shelf's card — state here, behaviour in `PostGridListRowCell+Dress.swift`
    /// How this cell draws — set by its host (`ForYouGridPage` sets `.row`
    /// on its lists' rows).
    ///
    /// ⚠️ THE DRESS CHANGES THE GROUND, AND THE TWO TRAILING ENDS. The
    /// caption, the band's leading edge and the preview keep every number
    /// they have: a row stands on the page's margin because its SECTION
    /// narrows (`PostGridListLayout.rowInset`), so the post page's register,
    /// built on `captionInset`, is untouched. What a row moves (#2289) is
    /// the closing line's column and the "..."'s — onto the caption's, both
    /// sides (`closingLineInset(for:)`, `bandTrailingInset(for:)`); the
    /// shared constants (`contentInset`, `captionInset`, `actionLineInset`)
    /// stay as they are.
    public var dress: Dress = .card {
        didSet {
            guard dress != oldValue else { return }
            applyDress()
            hangLineEnds()
        }
    }
    /// The hairlines this row draws above and below it — the page decides
    /// from the row's neighbours (`ListSeparators`). Drawn only on a row.
    public var rowSeparators: RowSeparators = .none {
        didSet {
            guard rowSeparators != oldValue else { return }
            setNeedsLayout()
        }
    }
    /// What a collection's box and gutter show: the card's tone, or the page
    /// through a row.
    var rowGround: UIColor { dress == .row ? .clear : Self.cardFillColor }
    let topRule = UIView()
    let bottomRule = UIView()
    /// A row's press: the `.label` wash `AppControl` lays under a card
    /// action, here under the whole row — a row has no card to give way.
    let pressWash = UIView()

    override public func layoutSubviews() {
        super.layoutSubviews()
        layoutRowChrome()
    }

    private func layoutRowChrome() {
        let row = dress == .row
        let hairline = Surface.hairline(for: traitCollection)
        let offset = Self.separatorOffset
        // Every line is FULL (#2289): the screen's width, and the row stands
        // `rowInset` in from each edge.
        let bleed = PostGridListLayout.rowInset
        func frame(y: CGFloat) -> CGRect {
            CGRect(x: -bleed, y: y, width: bounds.width + bleed * 2, height: hairline)
        }
        topRule.isHidden = !row || rowSeparators.top == .none
        bottomRule.isHidden = !row || rowSeparators.bottom == .none
        topRule.frame = frame(y: -offset - hairline / 2)
        bottomRule.frame = frame(y: bounds.height + offset - hairline / 2)
        // The wash spans the row and half the gap either side, so two
        // neighbours' washes would meet on their hairline.
        pressWash.frame = bounds.insetBy(dx: -bleed, dy: -offset)
    }

    override public var isHighlighted: Bool {
        didSet {
            guard dress == .row, isHighlighted != oldValue else { return }
            let target: CGFloat = isHighlighted ? AppControl.Metrics.pressedWash : 0
            UIView.animate(
                withDuration: PressFeedback.Metrics.response, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.pressWash.alpha = target
            }
        }
    }

    /// The hairlines' frames in the row's space, nil when hidden. Tests.
    public var debugRuleFrames: (top: CGRect?, bottom: CGRect?) {
        layoutIfNeeded()
        return (topRule.isHidden ? nil : topRule.frame, bottomRule.isHidden ? nil : bottomRule.frame)
    }

    /// The dress's ground, corner and edge as drawn. Tests.
    public var debugDress: (fill: UIColor?, cornerRadius: CGFloat, borderWidth: CGFloat) {
        (card.backgroundColor, card.layer.cornerRadius, card.layer.borderWidth)
    }

    // MARK: - Select Text — state here, behaviour in `PostGridListRowCell+SelectText.swift`
    /// The caption made selectable in place, while a selection is up.
    var captionSelection: SelectableTextOverlay?

    /// - Parameter showsAuthorIdentity: false on a surface where the author is
    ///   the screen itself — a profile's own posts — so the band wears only
    ///   the date and the "..." rather than repeating the name above every
    ///   card.
    /// - Parameter captionLines: a card of a FIXED height — see
    ///   `fixedCaptionLines`. Nil: the list's card, sized to its content.
    public func configure(
        with post: GalleryPost, imagePipeline: ImagePipeline, captionExpanded: Bool = false,
        showsAuthorIdentity: Bool = true, captionLines: Int? = nil,
        showsVoice: Bool = VoicePostDisplay.areDrawn, showsEmbed: Bool = PostEmbeds.areDrawn
    ) {
        fixedCaptionLines = captionLines
        isCaptionExpanded = captionExpanded && captionLines == nil
        captionLabel.numberOfLines = isCaptionExpanded ? 0 : (captionLines ?? Self.captionLineLimit)
        // The fixed card's label cuts its own tail; the list's card writes
        // its ellipsis and "Show more" into the text (`composeCaption`).
        captionLabel.lineBreakMode = captionLines == nil ? .byWordWrapping : .byTruncatingTail
        // A showcase (#2216): its card under the author's words on the list's
        // card, the card alone on a shelf's. It outranks a voice: a post
        // carrying both shows the card, the one thing the caption's place
        // holds (the backend gives a showcase no voice).
        let embedSize = Self.embedSize(for: post, captionLines: captionLines, showsEmbed: showsEmbed)
        // A voice post (#2208): the voice in the caption's place — its words
        // under it on the list's card, the voice alone on a shelf's.
        let voiceSize: VoicePostDisplay.Size? = embedSize == nil
            ? Self.voiceSize(for: post, captionLines: captionLines, showsVoice: showsVoice) : nil
        let wordsGo = voiceSize == .compact || embedSize == .compact
        fullCaption = wordsGo ? "" : post.caption
        bindAuthorBand(to: post, imagePipeline: imagePipeline, showsIdentity: showsAuthorIdentity)
        showMoreRange = nil
        applyVoice(voiceSize, for: post)
        applyEmbed(embedSize, for: post, imagePipeline: imagePipeline)
        // Provisional: the real composition needs the row's final width, which
        // only `preferredLayoutAttributesFitting` knows. Set here so a cell
        // that is never sized (a measuring instance) still reads correctly.
        captionLabel.attributedText = Self.plain(fullCaption, font: captionLabel.font)
        let hasMedia = post.kind != .text
        mediaAspectRatio = post.aspectRatio
        mediaPageCount = post.isCollection ? post.pages.count : 1
        // Provisional, on whatever width this cell currently carries — the
        // authoritative pass is `preferredLayoutAttributesFitting`. Set here so
        // a cell that is never measured (a stand-in, a preview) is not left
        // with a zero-height preview.
        resolveMediaHeight(atWidth: bounds.width)
        mediaView.isHidden = !hasMedia
        // A COLLECTION's badge belongs to the page, not to the box: with mixed
        // pages the box has no single answer, and a badge over the whole
        // preview would sit on a photograph as often as on a clip.
        // ⚠️ RE-ASSERTED, not assumed. A flight can be in the air while this
        // row is reconfigured, and everything above has just set the furniture
        // visible. Without this the badge lights up mid-dismissal.
        if isHeroMediaConcealed { setHeroMediaConcealed(true) }
        NSLayoutConstraint.deactivate(hasMedia ? [] : mediaConstraints)
        NSLayoutConstraint.activate(hasMedia ? mediaConstraints : [])

        boundPostID = post.id
        actionsAnimate = false
        let bound = post.id
        DispatchQueue.main.async { [weak self] in
            guard let self, boundPostID == bound else { return }
            actionsAnimate = true
        }
        baseReactionCount = post.reactionCount
        configuredReactionCount = post.reactionCount
        applyReactionCount(animated: false)
        // A number the post does not have draws no action at all — nor does
        // a showcase, which takes no comments (#2216: the conversation is
        // the channel), whatever count the post carries.
        showsShowcase = embedSize != nil
        applyCommentCount(showsShowcase ? nil : post.commentCount, animated: false)
        // ⚠️ THE COUNT IS A CONTROL ON EVERY CARD, TEXT POSTS INCLUDED.
        //
        // It used to be switched off on a text post, on the argument that its
        // page IS its thread and tapping anywhere on the card already arrives
        // there — so the chip stayed drawn and did nothing. Reported from a
        // device as exactly that: the same capsule shrank under the finger on
        // a media card and was dead on a text card, "as if the button did not
        // work". One affordance, one answer: the chip always presses, and the
        // HOST decides where a text post's comments are — its own page, by
        // its own reveal, which is the route the argument was protecting.
        commentsAction.accessibilityLabel = "Comments"
        // ⚠️ AFTER the indicator has been configured below, since it is on the
        // line too — see the end of this method.

        // The media ground (#1771): the bone's own grey under the cover.
        mediaView.backgroundColor = Surface.mediaGround

        // A collection hands its pages to the carousel and stops here: the
        // box's own image view stays empty, which is what keeps a single-media
        // post on exactly the path it has always taken — same load, same video
        // surface, same cover.
        pageIndicator.configure(count: post.pages.count, current: 0)
        // Everything on the line is decided now: the counts, the date, the
        // indicator. The controls arrive from the host afterwards and re-ask.
        syncClosingLine()
        if post.isCollection {
            // The box behind the pages is the CARD, not the placeholder fill a
            // single-media row uses: with a gutter between items and one cropped
            // at the edge, that fill is on screen at rest and has to be the
            // surface the pages are lying on — the page itself on a list's
            // row (#2243), a shelf card's tone on a card.
            mediaView.backgroundColor = rowGround
            let carousel = makeCarouselIfNeeded()
            carousel.backgroundColor = rowGround
            carousel.isHidden = false
            carousel.configure(with: post.pages, imagePipeline: imagePipeline)
            cover.reset()
            return
        }
        carousel?.isHidden = true
        carousel?.cancelPendingWork()

        // ⚠️ A new post's cover cancels the previous load: a reconfigure
        // without a reuse (the profile gallery's `reconfigureItems`, a seeded
        // post then its hydrated one) used to leave it running beside the new
        // one, and whichever landed last won — the old URL's cover over the
        // right one (#781). The same post again keeps what it shows.
        guard hasMedia else {
            cover.reset()
            return
        }
        cover.load(post.thumbnailURL, pipeline: imagePipeline, item: post.id)
    }
}

extension PostGridListRowCell: GridPlaybackCell {}
