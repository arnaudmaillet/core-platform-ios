import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

/// The low, light gradient behind a tile's count (#1509): clear at its top,
/// `PostGridTileCell.countGradientOpacity` black at the tile's bottom edge.
/// Public so the tile's flight twin (`PostGridFlightCard`) wears it too.
public final class PostTileCountGradientView: UIView {
    override public class var layerClass: AnyClass { CAGradientLayer.self }

    /// Where it sits on a tile of `bounds`: along the bottom edge.
    public static func frame(in bounds: CGRect) -> CGRect {
        let height = min(PostGridTileCell.countGradientMaxHeight, bounds.height * PostGridTileCell.countGradientHeightFraction)
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(PostGridTileCell.countGradientOpacity).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Media tile

/// One square of the Media grid: photo thumbnail, or video poster + badge,
/// with the likes count resting bottom-trailing — caption2 over a soft
/// shadow and a LOW, LIGHT gradient (#1509: the count read on no picture at
/// all on a bright one), so the preview stays the star.
///
/// ⚠️ A NARROW TILE TAKES THE COMPACT REGISTER ON ITS OWN (#1509, the
/// owner's choice): below `compactWidth` — the snap feed's side list — the
/// count is smaller and tucked closer to the corner, so "♥ 812" fits whole.
/// No per-screen flag: the For You, profile and place grids are wider and
/// keep their size.
public final class PostGridTileCell: UICollectionViewCell {
    public static let reuseID = "PostGridTileCell"

    /// Below this width, the compact counter (#1509).
    public static let compactWidth: CGFloat = 90
    /// The compact counter's face.
    static let compactMetaFont = UIFont.systemFont(ofSize: 10, weight: .semibold)
    /// The gradient behind the count: how much of the tile's height it
    /// covers, and how dark it ends at the bottom edge.
    static let countGradientHeightFraction: CGFloat = 0.35
    static let countGradientMaxHeight: CGFloat = 64
    static let countGradientOpacity: CGFloat = 0.35

    /// The mosaic's rounding, and the default: it is paired with that layout's
    /// 1.5pt hairline gutter, where anything softer would leave visible pinches
    /// where four bricks meet.
    public static let mosaicCornerRadius: CGFloat = 10

    /// The brick's rounding, settable because the two grids that share this
    /// cell space their tiles differently — see
    /// `ChaoticSliceLayout.harmonisedGutter`. Gap and curve are one decision,
    /// so a surface that widens the gap sets this to match.
    public var cornerRadius: CGFloat = PostGridTileCell.mosaicCornerRadius {
        didSet { contentView.layer.cornerRadius = cornerRadius }
    }

    /// The floor a brick draws its cover on: a dark stage for video, whose
    /// poster may be unrenderable (or plain black in the simulator), and the
    /// system fill for everything else.
    ///
    /// Static because a stand-in needs the SAME answer with no cell to ask —
    /// see `PostGridTileStandInView`, where this is the view's own fill and the
    /// tile it holds is what fades over it. Two spellings of one colour would
    /// make the empty beat of a dismissal a different shade from the brick it
    /// lands on.
    /// The tile's ground: the media ground under a picture (#1771) — the
    /// bone's own grey, so a tile reads the same loading, missing or failed —
    /// and the card's for words.
    ///
    /// ⚠️ THE CARD'S TONE ON THE PLAIN PAGE (#2243): a tile of words — a
    /// chunk's, a shelf's text media card, a History square — is one grey
    /// step down from the white page the post lists lie on, where a white
    /// card would have no edge (`Surface.cardOnPlainPage`). The same answer
    /// for a tile and for every copy of it (a flight's card, a close's
    /// stand-in, a window's floor).
    public static func fillColor(for post: GalleryPost) -> UIColor {
        post.kind == .text ? Surface.cardOnPlainPage : Surface.mediaGround
    }

    /// The image the brick is currently showing — see `PostGridListRowCell`'s
    /// note for why a hero reads this rather than the image pipeline.
    public var renderedCover: UIImage? { media.renderedCover }

    /// A tile IS its media, edge to edge, so the whole cell is the rect
    /// visibility is measured against.
    public var videoMediaRect: CGRect { bounds }

    /// A tile IS its media: if a surface exists it is showing the only thing
    /// this cell has.
    public var isRenderingCurrentMedia: Bool { loadedVideoRenderView != nil }

    /// The surface an autoplaying tile renders into, built on first use so a
    /// grid of stills never allocates a player layer it will not use.
    ///
    /// Not a `lazy var`: the coordinator needs to ask whether a cell *could* be
    /// playing (`loadedVideoRenderView`) without the question itself allocating
    /// the layer, which is exactly what touching a lazy var would do.
    public func makeVideoRenderViewIfNeeded() -> VideoRenderView {
        // Above the still, below the badge and counters, so the furniture keeps
        // reading over moving video exactly as it does over a poster.
        media.makeVideoRenderViewIfNeeded()
    }

    /// The video surface if one was ever built, else nil — never allocates.
    public var loadedVideoRenderView: VideoRenderView? { media.video }

    /// Installs a flight card's live surface as this tile's own, at landing.
    ///
    /// The view arrives already rendering, so the tile has nothing to wait for
    /// — the alternative is starting a fresh layer that is blank for ~100ms
    /// just as the card is removed, which is the flash at the end of a
    /// dismissal.
    public func adoptVideoRenderView(_ view: VideoRenderView) {
        media.adopt(view)
    }

    /// Gives up the live surface so a hero flight can fly the *same* layer.
    ///
    /// Mirroring — attaching the player to a second `AVPlayerLayer` — cannot be
    /// seamless, because a freshly attached layer has no decoded frame and
    /// reports `isReadyForDisplay == false` for ~100ms. Measured. Moving the
    /// view that is already rendering has no such window: same layer, same
    /// player, same frame, just a different superview.
    ///
    /// The cell drops its reference; a later play builds a fresh surface.
    public func donateVideoRenderView() -> VideoRenderView? {
        media.donate()
    }

    /// Called when the collection view recycles this cell, so whoever loaned it
    /// a player takes it back. Mirrors `MapAnnotationView.onReuse`: a recycled
    /// cell that kept its player would render another post's video.
    public var onReuse: (() -> Void)?

    private let imageView = UIImageView()
    private static let metaFont = UIFont.postGridSystemFont(
        matching: .appFont(forTextStyle: .caption2), weight: .semibold
    )
    /// ⚠️ ONE NUMBER, and it is the LIKES (product call, 2026-09-30).
    ///
    /// A brick is small and read at a glance, in a mosaic of a dozen others;
    /// two numbers on it are two things to compare across every tile at once.
    /// It used to be reach — views, an `eye.fill` — on the reading that a
    /// tile is a way in and "how many got here" says whether to be one more.
    /// The app no longer shows views anywhere a post is drawn, so the tile
    /// carries the number every card and the feed carry: the heart, filled —
    /// the glyph a count over a picture wears (the cards' outline heart is a
    /// control; this is a read-out). The flight card mirrors it
    /// (`PostGridFlightCard`), in every gallery: For You's chunks and mosaic,
    /// a profile's Media, a place's grid.
    private let likes = PostMetricLabel(
        symbol: LikesSymbol.glyph, font: metaFont, color: .white, shadowed: true
    )
    /// The count's corner margins, regular and compact.
    private var likesTrailing: NSLayoutConstraint?
    private var likesBottom: NSLayoutConstraint?
    /// Behind the count: transparent at its top, `countGradientOpacity`
    /// black at the tile's bottom edge (#1509). Shown with the count.
    private let countGradient = PostTileCountGradientView()
    /// Whether the counter wears the compact register now.
    public private(set) var isCompact = false
    /// The cover and the live surface over it (#1088): the cover's arrival
    /// on the loading ladder — a reconfigure cancelling the load in flight
    /// (#781), a parked frame outranking a late thumbnail — and the surface's
    /// plumbing shared with every other hero source. Readable inside the
    /// package so a test can ask what is in flight.
    /// A stand-in's moving picture (#1294): over the cover, under the words —
    /// a twin's, never a loan, so it bypasses `media`.
    func installStandInLiveMedia(_ view: UIView) {
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.insertSubview(view, aboveSubview: imageView)
    }

    private(set) lazy var media: MediaSurface = {
        let media = MediaSurface(cover: imageView, in: contentView, coverSize: .full)
        media.debugLabel = "tile"
        media.onCoverLoaded = { [weak self] in self?.onCoverLoaded?() }
        media.onCoverFailed = { [weak self] in self?.onCoverFailed?() }
        return media
    }()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Surface.mediaGround
        contentView.clipsToBounds = true
        // Soft bricks, not hard edges. `cornerRadius` re-applies this whenever
        // a host wants the softer pairing; the curve stays continuous either
        // way, which is what keeps a widened radius from reading as a stadium.
        contentView.layer.cornerRadius = cornerRadius
        contentView.layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.pin(to: contentView)

        // ⚠️ THE COUNT CLOSES THE ROW, as it does on both of a card's
        // placements.
        //
        // A tile carries no date, so only half of the card's arrangement has
        // anything to say here — but that half is the half that matters: the
        // numbers gather at the trailing edge on every surface, and a mosaic of
        // bricks whose counters sat on the other side would be the one place
        // the eye had to look somewhere else for them.
        // Under the count, over the picture: added first so the count
        // (constrained next) sits above it.
        countGradient.isUserInteractionEnabled = false
        contentView.addSubview(countGradient)
        contentView.addSubview(likes)
        likes.translatesAutoresizingMaskIntoConstraints = false
        let trailing = likes.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
        let bottom = likes.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7)
        likesTrailing = trailing
        likesBottom = bottom
        NSLayoutConstraint.activate([
            trailing, bottom,
            likes.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - The ribbon

    /// A mark across the top edge (`TileRibbonView`) — on the CELL, not its
    /// content view, which clips: the chip straddles the edge. Built on first
    /// use; most tiles never wear one.
    private var ribbon: TileRibbonView?

    /// Wears `title` (and `symbolName`) as a chip across the tile's top
    /// edge, or none for nil — the sound sheet's "Original" (#1280).
    public func setRibbon(_ title: String?, symbolName: String? = nil) {
        guard let title else {
            ribbon?.isHidden = true
            return
        }
        let chip = ribbon ?? makeRibbon()
        chip.set(title: title, symbolName: symbolName)
        chip.isHidden = false
    }

    private func makeRibbon() -> TileRibbonView {
        let chip = TileRibbonView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.centerYAnchor.constraint(equalTo: topAnchor),
            chip.centerXAnchor.constraint(equalTo: centerXAnchor),
            chip.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
        ])
        ribbon = chip
        return chip
    }

    #if DEBUG
    /// The chip's frame in the cell, nil when it wears none.
    public var debugRibbonFrame: CGRect? {
        guard let ribbon, !ribbon.isHidden else { return nil }
        layoutIfNeeded()
        return ribbon.frame
    }
    #endif

    override public func prepareForReuse() {
        super.prepareForReuse()
        // The mark was this post's; the next host says whether it wants one.
        ribbon?.isHidden = true
        // A recycled cell must come back VISIBLE. A hero flight hides the tile
        // it is flying from, and that hide lives on the cell — so a cell
        // recycled while hidden carries the invisibility to whatever post it is
        // next bound to, and nothing on the reuse path would ever put it back.
        // One tile lost per flight whose cell got recycled before its unhide,
        // which is what made the gallery thin out over repeated round trips.
        isHidden = false
        alpha = 1
        // Hand the player back BEFORE anything else: a recycled cell that kept
        // its loan would show the previous post's video under the new post's
        // still. The coordinator clears its own bookkeeping in response.
        onReuse?()
        onReuse = nil
        onCoverLoaded = nil
        onCoverFailed = nil
        endVideoPreview()
        media.reset()
        // The viewer's stake was the last post's; the next host reads its own.
        setViewerStake(0)
        // The words were this post's; the next host says whether it wants
        // any (`configure(…showsInfo:)`).
        showsInfo = false
        infoPost = nil
        infoReferenceSize = nil
        infoDecidedSize = nil
        removeInfoOverlay()
        if voiceMarkIsBuilt {
            voiceMark.clear()
            accessibilityLabel = nil
        }
        if embedMarkIsBuilt {
            embedMark.clear()
            accessibilityLabel = nil
        }
    }

    // MARK: - A showcase's mark (#2216)

    /// A showcase's tile (behind `-channels`): its text face, the embed's
    /// mark — the channel's photo with its glyph, its name — in the middle,
    /// the caption gone. Not interactive: a tap is the tile's, it opens the
    /// post; a hold is the tile's preview.
    private lazy var embedMark: PostEmbedView = {
        let mark = PostEmbedView()
        mark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            mark.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -16),
        ])
        return mark
    }()

    /// Whether the mark was ever built: most tiles never wear one.
    private var embedMarkIsBuilt = false

    /// The size a tile gives a showcase's embed: the mark, for a text post
    /// with one and the switch on; nil otherwise. Pure.
    public static func embedSize(for post: GalleryPost, showsEmbed: Bool) -> PostEmbeds.Size? {
        post.kind == .text && PostEmbeds.shown(post.embed, drawn: showsEmbed) != nil ? .mark : nil
    }

    private func applyEmbedMark(_ size: PostEmbeds.Size?, for post: GalleryPost, imagePipeline: ImagePipeline) {
        guard let size, let embed = post.embed else {
            if embedMarkIsBuilt { embedMark.clear() }
            return
        }
        embedMarkIsBuilt = true
        embedMark.show(embed, size: size, pipeline: imagePipeline)
        // A mark takes no touch — `PostEmbedView` says so for `.mark` — and
        // the tile reads as one element: "Channel Harbour notes, 12.4K
        // subscribers".
        accessibilityLabel = embed.channel.map(ChannelEmbedCopy.accessibilityLabel)
    }

    /// Whether the tile's words give way to a mark — a voice's or a
    /// showcase's — in their place.
    private var wearsCaptionMark: Bool {
        (voiceMarkIsBuilt && !voiceMark.isHidden) || (embedMarkIsBuilt && !embedMark.isHidden)
    }

    #if DEBUG
    /// The showcase's mark the tile wears in its words' place, nil for none.
    public var debugEmbedMark: PostEmbedView? { embedMarkIsBuilt && !embedMark.isHidden ? embedMark : nil }
    #endif

    // MARK: - A voice post's mark (#2208)

    /// A voice post's tile (behind `-voice-posts`): its text face, the mark —
    /// a mic, a still waveform, the length — in the middle, the caption gone.
    /// Not interactive: a tap is the tile's, it opens the post.
    private lazy var voiceMark: VoicePostCaptionView = {
        let mark = VoicePostCaptionView()
        mark.isUserInteractionEnabled = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            mark.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -8),
        ])
        return mark
    }()

    /// The size a tile gives a voice post's caption: the mark, for a text
    /// post that speaks with the switch on; nil otherwise. Pure.
    public static func voiceSize(for post: GalleryPost, showsVoice: Bool) -> VoicePostDisplay.Size? {
        showsVoice && post.kind == .text && post.voice != nil ? .mark : nil
    }

    private func applyVoiceMark(_ size: VoicePostDisplay.Size?, for post: GalleryPost) {
        guard let size, let voice = post.voice else {
            // Only a tile that wore a mark built it, and only that one says so.
            if voiceMarkIsBuilt { voiceMark.clear() }
            return
        }
        voiceMarkIsBuilt = true
        voiceMark.show(
            postID: post.id.rawValue, url: voice.url, duration: voice.duration, levels: voice.waveform,
            author: post.authorName, size: size
        )
        accessibilityLabel = voiceMark.accessibilityDescription
    }

    /// Whether the mark was ever built: most tiles never wear one, and a
    /// lazy view touched on every configure would be built for each.
    private var voiceMarkIsBuilt = false

    #if DEBUG
    /// The mark the tile wears in its words' place, nil for none.
    public var debugVoiceMark: VoicePostCaptionView? { voiceMarkIsBuilt && !voiceMark.isHidden ? voiceMark : nil }
    #endif

    override public func layoutSubviews() {
        super.layoutSubviews()
        // The variant follows the tile's size — a cell configured before the
        // collection view sized it decides here, once it has a size.
        refreshInfoOverlay()
        infoOverlay?.frame = contentView.bounds
        applyCounterRegister()
        countGradient.frame = PostTileCountGradientView.frame(in: contentView.bounds)
        countGradient.isHidden = likes.isHidden
    }

    /// The compact register below `compactWidth`, the regular one above
    /// (#1509): its face and its corner margins.
    private func applyCounterRegister() {
        let compact = bounds.width > 0 && bounds.width < Self.compactWidth
        guard compact != isCompact else { return }
        isCompact = compact
        likes.setFont(compact ? Self.compactMetaFont : Self.metaFont)
        likes.glyphSpacing = compact ? 2 : 4
        likesTrailing?.constant = compact ? -4 : -8
        likesBottom?.constant = compact ? -4 : -7
    }

    /// Puts a cover on the tile immediately, without waiting for the async load
    /// that is already in flight to come back.
    ///
    /// Closes a race the autoplay gate would otherwise lose: `configure` asks
    /// the cache once, and if the image lands *after* that (from the prefetch)
    /// the cache has it while this cell is still showing nothing. A gate that
    /// consulted the cache would pass, and the tile would start playing with a
    /// blank face anyway — which is the exact failure the gate exists to
    /// prevent.
    public func applyCover(_ image: UIImage) {
        media.applyCover(image)
    }

    public func showReturnStill(_ image: UIImage) {
        media.showReturnStill(image)
    }

    /// A tile on a page that is black in either appearance (the snap feed's
    /// side list, #1772): its picture's ground and its bone are the on-dark
    /// media ground — the tile's own bone, never a host's second one over it.
    public var groundsOnDark = false

    /// Whether the cover's own bone shows now.
    public var showsCoverBone: Bool { media.coverSlot.showsBone }

    /// Fired when the cover lands from an async load.
    ///
    /// Autoplay is gated on the cover being present, and the gate is evaluated
    /// by a reconcile that normally only runs on scroll. Without this, a tile
    /// whose cover arrives while the grid is sitting still would fail the gate
    /// once and never be asked again — it would simply never play.
    public var onCoverLoaded: (() -> Void)?
    /// The cover could not be loaded: a host's waiting skeleton stills
    /// (#1553).
    public var onCoverFailed: (() -> Void)?

    /// Reveals the video surface once a player has been attached. The still
    /// stays underneath as the poster, so the first frame replaces it rather
    /// than flashing black.
    public func beginVideoPreview() {
        // The cover keeps the tile until there is video to replace it with.
        // Unhiding here put an empty surface over the cover for the whole
        // decode start-up — measured at ~1.2s on a cold tile — which is a tile
        // going dark at rest, before any transition is involved.
        media.beginPreview()
        #if DEBUG
        // Whether the tile had a cover AT THE MOMENT playback started. Holding
        // the surface back is only worth anything if there is something behind
        // it; a nil here means the tile is black no matter what the renderer
        // does, and the fix belongs in the cover pipeline rather than here.
        if ProcessInfo.processInfo.arguments.contains("-avsbdl-log") {
            print(String(format: "[avsbdl] %.3f tile beginVideoPreview cover=%@",
                         CACurrentMediaTime(), media.renderedCover == nil ? "NIL" : "present"))
        }
        #endif
    }

    /// Back to a still tile.
    public func endVideoPreview() {
        // Faded, not switched off. This runs for every tile `beginHandoff`
        // stops as a flight leaves, and a binary hide snaps each of their
        // covers back in a single frame — several thumbnails popping at once,
        // on the grid, at exactly the moment the viewer is watching the flight.
        media.endPreview()
    }

    #if DEBUG
    /// The count the tile shows, as drawn — nil while it is hidden.
    public var debugCounterText: String? {
        if let like = infoOverlay?.likeReadout { return like.debugCountText }
        return likes.isHidden ? nil : likes.debugText
    }
    /// Whether the count's heart is the points' red (`setViewerStake`).
    public var debugIsStaked: Bool { viewerStaked }
    /// The author-and-caption foot the tile wears — nil while it wears none.
    public var debugInfoOverlay: PostCardCaptionOverlay? { infoOverlay }
    /// Whether the tile's own likes readout (bottom-right) is drawn.
    public var debugShowsCornerLikes: Bool { !likes.isHidden }
    /// Whether the gradient behind the count is drawn (#1509).
    public var debugShowsCountGradient: Bool { !countGradient.isHidden && countGradient.frame.height > 0 }
    #endif

    /// Takes `post`'s counter and nothing else — see the list row's.
    public func updateCounts(from post: GalleryPost) {
        likes.set(post.reactionCount)
        infoOverlay?.setLikeCount(post.reactionCount)
        applyCornerLikes()
    }

    /// What `configure` drew — `postLikeCount`.
    private var configuredLikeCount: Int64?

    public var postLikeCount: Int64? {
        configuredLikeCount
    }

    public func showLikeCount(_ count: Int64) {
        guard var post = infoPost, let shown = post.reactionCount, shown != count else { return }
        // Kept on the post too: the words' overlay is rebuilt from it when
        // the tile changes size.
        post.reactionCount = count
        infoPost = post
        likes.set(count)
        infoOverlay?.setLikeCount(count)
        // ⚠️ `set` shows the readout again (#1186): a like landing on a tile
        // whose words carry the heart drew a SECOND heart in the corner.
        applyCornerLikes()
    }

    // MARK: - The viewer's like

    /// Whether the viewer has staked on the post the tile shows.
    private var viewerStaked = false

    /// What the viewer has staked on the post: the count's heart turns the
    /// points' red once there is any — a READOUT still, never a control
    /// (For You's tiles, through `PostCardStaking.bindReadout`). The count
    /// stays the post's. The flight card draws the same heart
    /// (`PostGridFlightCard`'s `viewerStake`), so a landing never recolours.
    public func setViewerStake(_ total: Int) {
        // The words' heart too, whatever the corner's state: it is drawn
        // with the total, and a variant built later reads it from here.
        setInfoViewerStake(total)
        let staked = total > 0
        guard staked != viewerStaked else { return }
        viewerStaked = staked
        likes.setGlyph(
            systemName: LikesSymbol.glyph, color: staked ? LikesSymbol.tint : .white
        )
    }

    // MARK: - Author and caption

    /// Whether the tile wears its post's author and the start of its caption
    /// over the picture, when it is large enough for them (`PostTileInfo`) —
    /// the Following card's foot, its heart closing the author line. Set by a
    /// host at `configure` — For You's chunks and its Discover gallery do;
    /// off, the tile is the picture and its likes, as on every other grid.
    public private(set) var showsInfo = false
    /// The post the words are drawn from.
    private var infoPost: GalleryPost?
    private var infoImagePipeline: ImagePipeline?
    /// The size the variant is decided and the words wrapped at, for a COPY
    /// that travels with a window (`PostGridTileStandInView`) — see
    /// `PostCardCaptionOverlay` for why a copy never re-lays out. Nil: the
    /// tile's own size, as any cell.
    private var infoReferenceSize: CGSize?
    /// What the viewer has staked on the post, for the overlay's heart.
    private var infoViewerStake = 0
    private var infoOverlay: PostCardCaptionOverlay?
    /// The variant the tile wears now.
    public private(set) var infoVariant: PostTileInfo.Variant = .none
    /// The size `infoVariant` was decided at — nil until the next decision.
    private var infoDecidedSize: CGSize?

    /// The words a tile of `restingSize` wears, built and laid out at that
    /// size — what a flight carries as the tile's resting furniture
    /// (`PostGridFlightCard.installRestingOverlay`), so the card takes off
    /// wearing exactly what the tile wore and the flight fades it. Nil when a
    /// tile of that size wears none.
    public static func makeInfoOverlay(
        for post: GalleryPost, restingSize: CGSize, imagePipeline: ImagePipeline?, viewerStake: Int = 0,
        showsVoice: Bool = VoicePostDisplay.areDrawn, showsEmbed: Bool = PostEmbeds.areDrawn
    ) -> PostCardCaptionOverlay? {
        let variant = PostTileInfo.variant(for: restingSize)
        guard variant != .none else { return nil }
        let overlay = makeInfoOverlay(
            for: post, variant: variant, referenceSize: restingSize,
            imagePipeline: imagePipeline, viewerStake: viewerStake,
            voiceAlone: voiceSize(for: post, showsVoice: showsVoice) != nil
                || embedSize(for: post, showsEmbed: showsEmbed) != nil
        )
        overlay.frame = CGRect(origin: .zero, size: restingSize)
        UIView.performWithoutAnimation { overlay.layoutIfNeeded() }
        return overlay
    }

    /// The one recipe, for the tile and every copy of it.
    ///
    /// The heart is ALWAYS there (a tile always shows its likes), a readout
    /// like the corner's it replaces. The text shadow is drawn into the glyphs: a screen of tiles is
    /// a dozen overlays at once, and a layer shadow on each label would be an
    /// offscreen pass apiece (`PostCardCaptionOverlay.TextShadow`).
    private static func makeInfoOverlay(
        for post: GalleryPost, variant: PostTileInfo.Variant, referenceSize: CGSize?,
        imagePipeline: ImagePipeline?, viewerStake: Int, voiceAlone: Bool
    ) -> PostCardCaptionOverlay {
        PostCardCaptionOverlay(
            // A voice post's tile wears its mark, alone, in the words' place
            // (#2208): the author line stays, the caption goes.
            post: post, placement: .onMedia, captionLines: voiceAlone ? 0 : variant.captionLines,
            referenceSize: referenceSize, imagePipeline: imagePipeline, viewerStake: viewerStake,
            textShadow: .inline
        )
    }

    /// Builds, swaps or drops the overlay to match the tile's size — only
    /// when the VARIANT changes, so a layout pass at the same size costs one
    /// comparison and the words are laid out once per tile.
    private func refreshInfoOverlay() {
        let size = infoReferenceSize ?? contentView.bounds.size
        // Decided once per size: a layout pass at the size already decided
        // (every pass but a resize) asks nothing of the rule or the fonts.
        guard size != infoDecidedSize else { return }
        infoDecidedSize = size
        let variant: PostTileInfo.Variant = showsInfo && infoPost != nil && size.width > 0 && size.height > 0
            ? PostTileInfo.variant(for: size)
            : .none
        guard variant != infoVariant else { return }
        removeInfoOverlay()
        infoVariant = variant
        if variant != .none, let infoPost {
            let overlay = Self.makeInfoOverlay(
                for: infoPost, variant: variant, referenceSize: infoReferenceSize,
                imagePipeline: infoImagePipeline, viewerStake: infoViewerStake,
                voiceAlone: wearsCaptionMark
            )
            overlay.frame = contentView.bounds
            // Above the picture and any video surface (both sit just above
            // the image view), below the corner readout it replaces.
            contentView.insertSubview(overlay, belowSubview: likes)
            infoOverlay = overlay
        }
        applyCornerLikes()
    }

    /// The corner count, unless the words carry the heart: then it closes
    /// the author line, as on a Following card, and two hearts on one tile
    /// would be one too many.
    private func applyCornerLikes() {
        likes.isHidden = infoOverlay != nil
        countGradient.isHidden = likes.isHidden
    }

    private func removeInfoOverlay() {
        infoOverlay?.removeFromSuperview()
        infoOverlay = nil
        infoVariant = .none
        applyCornerLikes()
    }

    private func setInfoViewerStake(_ total: Int) {
        infoViewerStake = total
        infoOverlay?.setViewerStake(total)
    }

    /// - Parameter showsInfo: see `showsInfo`.
    /// - Parameter infoReferenceSize: for a copy that rides a window — see
    ///   `infoReferenceSize`. Nil for a cell.
    public func configure(
        with post: GalleryPost, imagePipeline: ImagePipeline,
        showsInfo: Bool = false, infoReferenceSize: CGSize? = nil,
        showsVoice: Bool = VoicePostDisplay.areDrawn, showsEmbed: Bool = PostEmbeds.areDrawn
    ) {
        // A showcase's tile: its text face, the card's mark in the words'
        // place (#2216). It outranks a voice, as on the list's card.
        let embedSize = Self.embedSize(for: post, showsEmbed: showsEmbed)
        // A voice post's tile: its text face, its mark in the words' place (#2208).
        let voiceSize: VoicePostDisplay.Size? = embedSize == nil ? Self.voiceSize(for: post, showsVoice: showsVoice) : nil
        applyVoiceMark(voiceSize, for: post)
        applyEmbedMark(embedSize, for: post, imagePipeline: imagePipeline)
        // The media ground under a picture, the card under words (#1771) —
        // on a dark page, the on-dark ground and bone (`groundsOnDark`).
        contentView.backgroundColor = groundsOnDark && post.kind != .text
            ? Surface.mediaGroundOnDark : Self.fillColor(for: post)
        media.coverSlot.bone?.fill = groundsOnDark ? Surface.mediaGroundOnDark : Surface.mediaGround

        likes.set(post.reactionCount)
        configuredLikeCount = post.reactionCount

        // The words: a new post is a new overlay, whatever the variant.
        removeInfoOverlay()
        self.showsInfo = showsInfo
        infoPost = post
        infoImagePipeline = imagePipeline
        self.infoReferenceSize = infoReferenceSize
        infoDecidedSize = nil
        refreshInfoOverlay()

        // ⚠️ A new post's cover cancels the previous load: a reconfigure
        // without a reuse otherwise left it racing the new one, and an old
        // cover could land over the right one (#781). A cover that lands after
        // the tile started playing becomes the surface's poster — the
        // difference between a cold flight showing the thumbnail and showing
        // nothing — and is announced, for the autoplay gate.
        //
        // At the tile's DRAWN size (#1505, as #1086 did for avatars): a grid
        // tile a third of the screen wide is a 512 px decode, not 1200 px.
        // The cell is laid out by the time it is configured; a copy that is
        // not yet keeps the full picture.
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        media.coverSize = Self.coverBucket(forDrawnSize: bounds.size, scale: scale)
        media.loadCover(post.thumbnailURL, pipeline: imagePipeline, item: post.id)
    }

    /// How much a tile's cover may be enlarged to stay in a smaller bucket: a
    /// 3:4 tile a third of a 402 pt screen wide is 528 px tall at @3x, a few
    /// percent over 512 — invisible at tile size, where the next bucket is a
    /// 1200 px decode, five times the memory.
    static let coverUpscaleSlack: CGFloat = 1.15

    /// The bucket a tile's cover is decoded at, from the size it is drawn at
    /// (#1505): `.px512` for a grid tile, the full picture for a tile larger
    /// than that (a slice's lead, a card) or one not laid out yet. Never a
    /// "small" bucket, which is the avatars' namespace. The grid's lookahead
    /// asks the same, so the tile finds its prefetch in memory.
    public static func coverBucket(forDrawnSize size: CGSize, scale: CGFloat) -> ImageBucket {
        guard size.width > 0, size.height > 0 else { return .full }
        let pixels = max(size.width, size.height) * max(scale, 1) / coverUpscaleSlack
        return max(.px256, ImageBucket(fittingPixels: pixels))
    }

    /// What a grid's lookahead asks for a tile's cover at `indexPath`: the
    /// bucket the tile will decode it at, from the layout's size for it.
    @MainActor
    public static func coverRequest(_ url: URL, at indexPath: IndexPath, in collectionView: UICollectionView) -> ImageRequest {
        guard let drawn = collectionView.layoutAttributesForItem(at: indexPath)?.size else { return ImageRequest(url: url) }
        let scale = collectionView.traitCollection.displayScale > 0 ? collectionView.traitCollection.displayScale : 3
        return ImageRequest(url: url, size: coverBucket(forDrawnSize: drawn, scale: scale))
    }
}

extension PostGridTileCell: GridPlaybackCell {}

extension PostGridTileCell: PostCardLikeReadout {}
