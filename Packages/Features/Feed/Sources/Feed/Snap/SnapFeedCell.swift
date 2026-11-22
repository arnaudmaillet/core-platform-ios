import MediaCore
import CoreModels
import CoreStorage
import CoreNavigation
import Transitions
import DesignSystem
import MediaPlayback
import PostGrid
import PostSurfaces
import UIKit
import LaunchArguments
import ThreadKit

/// A full-screen snap cell: cover-fit media under a `SnapChromeView` overlay
/// (scrim, full-width caption). Text-only posts render as an empty shell —
/// black page, no caption/ticker — under the screen chrome, until their
/// dedicated layout exists.
///
/// It reuses `FeedItemDisplayModel` as-is — only the fields relevant to a
/// full-bleed page (`mediaURL`, `thumbnailURL`, caption) are read; author
/// identity is the navigation bar's concern, and the precomputed heights are
/// ignored because every cell is bounds-sized.
///
/// The cell plays no part in the hero transition's animation: the flight is a
/// self-contained card owned by the animator (carrying its own chrome replica),
/// and the whole feed is simply revealed at landing. Nothing mutates a live
/// cell mid-flight.
final class SnapFeedCell: UICollectionViewCell, SnapCellLifecycle {
    static let reuseIdentifier = "SnapFeedCell"

    /// The media component: the video/photo render surfaces, full-bleed in
    /// BOTH states. The cell drives playback into `mediaCard.renderView`
    /// and gates the drift; the card owns the surfaces' motion. Engaging
    /// the comments does not move it — it becomes the page's background,
    /// with the stream reading over it. Text posts leave it empty
    /// (surfaces hidden), so the black contentView shows through.
    let mediaCard = SnapMediaCardView()

    /// Freezes this cell's media pages for the length of a dismissal — see
    /// `MediaCarouselView.setScrollEnabled`.
    func setCarouselScrollEnabled(_ enabled: Bool) {
        mediaCard.setCarouselScrollEnabled(enabled)
    }

    /// Whether this cell has pages a dismissal has to freeze — diagnostics.
    var hasMediaCarousel: Bool { mediaCard.showsCollection }
    /// A spare when one is ready (#2126): a pushed feed builds its first
    /// cell in the tap's turn.
    let chrome = SnapChromeView.make()

    /// The bucket the caption's emotes are drawn at (#1504).
    var captionEmotePixelSide: Int { chrome.captionEmotePixelSide }

    /// A large centred play glyph shown while the active video is user-paused.

    private var representedID: PostID?

    /// Which post this cell's playback belongs to, for the pool's sharing rule.
    ///
    /// ⚠️ Two posts carrying the same file are two playbacks. Sharing a player
    /// between them makes pausing one freeze the other — see `playingScope` in
    /// `VideoPlaybackController`. The card and this page sharing one is the case
    /// the rule exists FOR, and they agree here because they name the same post.
    var playbackScope: String? { representedID?.rawValue }
    /// The post this page shows.
    var representedPostID: PostID? { representedID }
    /// Where this page's clip starts when a hero flight opened it mid-clip
    /// (#625) — the moment the card's picture was showing. Spent by the first
    /// start; nil starts at the beginning, as always.
    var flightMediaStartTime: TimeInterval?
    private(set) var mediaURL: URL?
    private(set) var mediaKind: MediaKind = .image

    /// The stream this page should be playing RIGHT NOW, nil for none.
    ///
    /// ⚠️ Every playback path used to ask `mediaKind == .video` and take
    /// `mediaURL`, and both answer for the post's HEAD attachment. A collection
    /// whose first page is a photograph is a `.photo` post — so a clip on page
    /// two was unreachable, and a post that DID lead with a clip would have
    /// played it behind every other page.
    ///
    /// Routing both questions through one property is what let the rest of this
    /// file stay as it is: the surface, the parking, the mirroring and the
    /// landing all still work on `mediaCard.renderView` by identity.
    var activeVideoURL: URL? {
        if mediaCard.showsCollection { return mediaCard.currentPageVideoURL }
        return mediaKind == .video ? mediaURL : nil
    }

    /// Whether there is anything to play at all — the replacement for the
    /// `mediaKind == .video` gates.
    var playsVideo: Bool { activeVideoURL != nil }

    /// The surface the page's clip draws on, for a second surface to show
    /// the same playback (the side list's tile of this post, #1581). Nil: no
    /// single clip on show (a photo, text, a collection).
    var liveVideoSurface: VideoRenderView? {
        playsVideo && !mediaCard.showsCollection ? mediaCard.renderView : nil
    }
    /// Whether the clip under the finger is actually running — the cover's
    /// record turns exactly while it is.
    var isClipAdvancing: Bool {
        guard let videoPlayback, let surface = audibleSurface else { return false }
        return videoPlayback.isAdvancing(in: surface)
    }
    private(set) var isChromeHeldForFlight = false

    /// The surface the viewer should HEAR when this page owns the screen: the
    /// clip on the page under the finger, nil on a photograph or a text page.
    var audibleSurface: VideoRenderView? {
        guard playsVideo else { return nil }
        return mediaCard.showsCollection ? mediaCard.currentPageSurface : mediaCard.renderView
    }

    /// The carousel's autoplay, its retention window and its warm-ups (#2521).
    private(set) lazy var carouselPlayback = SnapCarouselPlayback(host: self)
    /// The pool this page plays through. Stored on `playback`, which drives
    /// the viewer's pauses, the playhead and the scrub through the same one.
    private(set) var videoPlayback: VideoPlaybackController? {
        get { playback.pool }
        set { playback.pool = newValue }
    }
    /// The viewer's hand on the clip and the playhead fed to the media bar —
    /// see `SnapCellPlayback`. Always on the watched surface, asked each time.
    private(set) lazy var playback = SnapCellPlayback(
        surface: { [weak self] in self?.mediaCard.renderView },
        isActive: { [weak self] in self?.isActive ?? false }
    )
    // The photograph's and the poster's load is the card's media slot
    // (`SnapMediaCardView.loadPicture`, #1505): a cache hit drawn in the
    // configure pass, a new post cancelling the load in flight, a late answer
    // for a post this cell no longer shows landing nowhere — and, between,
    // the bone rather than the black floor and a spinner.
    private(set) var isActive = false
    /// The clip's preview while a finger browses the strip (#1734, #2521).
    private(set) lazy var mediaBrowse = SnapBrowseMirror(host: self)

    // MARK: Comments engagement

    /// The user asked for the comments surface (the empty-state pill today;
    /// more entry points later). Carries the represented post.
    var onRequestComments: ((PostID) -> Void)?
    /// The page's band ran low on reactions: the screen may fetch the post's
    /// next page of comments (#2005).
    var onReactionsRunningLow: ((PostID) -> Void)?
    /// The rail's boost anchor asked to spend on the represented post (an
    /// amount, or one ×100 shot). The owning VC answers through the wallet and
    /// calls back `playBoostConfirmation` / `playBoostDenied` — the cell
    /// holds no balance opinion of its own.
    var onRequestBoost: ((PostID, WalletStakeSpend) -> Void)?
    /// The anchor's menu asked to take back this post's session spend —
    /// the VC owns the tally and the refund.
    var onRequestBoostUndo: ((PostID) -> Void)?

    // MARK: Unavailable post (#1409)

    /// The "This post isn't available" block and its state (#1409, #2521).
    private(set) lazy var unavailablePost = SnapUnavailableBlock(host: self)
    /// Whether the represented post is one the server shows the viewer no more.
    var isPostUnavailable: Bool { unavailablePost.isPostUnavailable }

    func setPostUnavailable(_ unavailable: Bool) { unavailablePost.setPostUnavailable(unavailable) }

    /// Boost feedback pass-throughs — the chrome owns the anchor and its
    /// theatre; the VC owns the wallet verdict that picks which one plays.
    func playBoostConfirmation(amount: Int) { chrome.boostReceipts.playBoostConfirmation(amount: amount) }
    func playBoostDenied() { chrome.boostReceipts.playBoostDenied() }
    func playBoostRefund(amount: Int) { chrome.boostReceipts.playBoostRefund(amount: amount) }
    /// The viewer's cumulative spend on this post — the anchor's number
    /// face. Set at configure (from the wallet's ledger) and again after
    /// each confirmed spend; chrome reset returns it to 0 on reuse.
    func setBoostTotal(_ total: Int, animated: Bool = false) { chrome.setBoostTotal(total, animated: animated) }
    /// The post's live like count — see `SnapChromeView.setPostLikeCount`.
    func setPostLikeCount(_ count: Int64?) { chrome.setPostLikeCount(count) }
    /// The sound bubble's face (#671) — see `SnapChromeView.setSoundFace`.
    func setSoundFace(_ face: SnapSoundFace?) { chrome.setSoundFace(face) }
    /// The bubble as the post's Share (#1999) — see `SnapChromeView.setSlotSharesPost`.
    func setSlotSharesPost(_ shares: Bool, holdArmsShare: Bool = false) {
        chrome.setSlotSharesPost(shares, holdArmsShare: holdArmsShare)
    }
    /// Turns the sound bubble's cover while the post plays (#671).
    func setSoundSpinning(_ spinning: Bool) { chrome.actionColumn.setSoundSpinning(spinning) }
    /// The sound bubble was tapped: the screen opens the sound sheet (#671).
    var onRequestSoundSheet: (() -> Void)?
    /// The sound bubble's way back (#1929): shown while the comments are
    /// scrolled away from their start.
    func setSoundShowsReturn(_ shows: Bool, down: Bool = false) { chrome.setSoundShowsReturn(shows, down: down) }
    /// The way back was tapped: the screen scrolls the comments to the top.
    var onRequestSoundReturn: (() -> Void)?

    /// A text page's like stands in the screen's footer (#1924): no pill
    /// in its column.
    func setLikeInFooter(_ inFooter: Bool) { chrome.actionColumn.likeInFooter = inFooter }
    /// The sound bubble wears the post's Share (#1999) and was tapped: the
    /// screen opens the share sheet.
    var onRequestShare: (() -> Void)?
    /// The anchor's wallet context (affordability + undoable tally) —
    /// pushed at configure and on every wallet change.
    func setBoostContext(balance: Int, undoable: Int, stakeShots: Int = 0) {
        chrome.actionColumn.setBoostContext(balance: balance, undoable: undoable, stakeShots: stakeShots)
    }
    /// pager INTERACTIVELY — the strip-side mirror of the composer bar's
    /// page-swipe. The cell forwards each pan phase with the raw vertical
    /// translation and velocity; the host hand-moves `contentOffset` so the
    /// whole engaged layer (which rides inside this cell) follows the finger
    /// in real time, settling on release.
    var onRequestCommentsPageDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)?
    /// Whether the cell is in the comments-engaged layout (media docked in
    /// the strip's slot, chrome faded out, caption re-homed beside the
    /// media). Pure layout state: playback is deliberately untouched.
    private(set) var isCommentsEngaged = false
    /// The frozen screen thresholds (`applyChromeInsets`) — also the strip's
    /// vertical datum, so the slot math shares the chrome's inset authority.
    private(set) var frozenInsets: UIEdgeInsets = .zero
    /// The engaged state's comments region: a cell-owned container spanning
    /// the strip's bottom to the cell's bottom edge. The comments UI itself
    /// is NOT cell state — the feed VC installs a child controller's view
    /// via `installComments` on engage and reclaims it on disengage, so
    /// thread data, scroll position, and a half-typed reply never live in a
    /// recycled cell. Z-order: above the media (which vacates the region),
    /// below the chrome (the action rail floats over it).
    /// The window a masked-hero opening is seen through — see
    /// `beginMaskedRevealForFlight`. Non-nil only for the length of a flight.
    private(set) var flightMask: UIView?
    private var alphaForMaskedReveal: CGFloat = 1
    private var groundForMaskedReveal: UIColor?
    /// ⚠️ ITS OWN FLAG, not a re-read of `groundForMaskedReveal`.
    ///
    /// The opening and the dismissal borrow the same two preparations — the
    /// media hidden, the ground cleared — and the first version guarded the
    /// dismissal on the stored ground being nil. A masked OPENING leaves that
    /// ground stored, so the dismissal that followed it declined to run and
    /// the thread stopped receding on exactly the pages that opened with one.
    private var isEngagedDismissing = false
    /// Whether the grab moving the page is a live grab (#1915): the page's
    /// whole interface rides it, untouched until the release commits — not
    /// the engaged thread, which recedes with the finger.
    private(set) var isLiveGrab = false
    /// Everything the page draws, in one frame-managed view — see
    /// `buildLayout`. A transition moves this and nothing inside it.
    let pageStage = UIView()
    /// The page's action column, ABOVE the chrome (#695) — the stage's twin:
    /// same bounds, same centre, same transform, written together
    /// (`stages`), so every movement of the page carries the column.
    ///
    /// ⚠️ #1917: the column used to sit in `contentView` itself, and the
    /// engaged dismissal moved only `pageStage` — the folded sound record
    /// stood still on the screen while the page left, and outside the card
    /// on some frames (the owner's film). Forwarding each transform by hand
    /// (#1549's side-list shift) is how it was forgotten; the twin cannot
    /// be. Transparent to every touch but the column's buttons.
    let columnStage = SnapActionColumnLayer()
    /// The page's two stages, which every transition writes as one.
    var stages: [UIView] { [pageStage, columnStage] }
    /// The grab's current mapping of page onto card — the scale, and the rect
    /// it is mapping onto — held so a layout pass cannot be the last word on
    /// where the page is.
    /// What each travelling layer's opacity was when the grab began — an
    /// abandoned one has to put back exactly that, and a starting one has to
    /// begin from it.
    private var restingAlphas: [CGFloat] = []
    private let commentsContainer = SnapCommentsContainerView()
    private var commentsContainerConstraints: [NSLayoutConstraint] = []
    /// The engaged header's frost: a dissolving blur band across the top
    /// inset, so the nav chrome stays legible where comment rows glide
    /// under it. A SIBLING of the comments container, not a child, so it
    /// never rides the stream's transform.
    private let headerFrost = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.headerFrostMaskColors,
        maskLocations: SnapCommentsLayout.headerFrostMaskLocations
    )
    private var headerFrostConstraints: [NSLayoutConstraint] = []
    /// The glass card's interactive exit pan — the composer bar's
    /// finger-connected swipe, mirrored onto the ENTIRE top floating
    /// card (media tile, caption column, music line, metrics row: one
    /// object, one gesture). Attached to the CELL (not the content view)
    /// so the cell's own `gestureRecognizerShouldBegin` override is its
    /// begin-time gate, exactly the bar's mechanism.
    private let cardSwipeRecognizer = UIPanGestureRecognizer()

    /// The viewer paged this post's collection. The screen forwards it to
    /// whatever opened the feed, so the card behind can follow.
    var onMediaPageChanged: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        // A tap on the picture toggles play/pause; the delegate rejects taps
        // that land on an interactive control (the chrome's shortcut rail), and
        // `playbackTapRegionContains` rejects the ones outside the media band.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tap.delegate = self
        contentView.addGestureRecognizer(tap)

        // Hold to pause: the clip stops while the finger is down and resumes
        // when it lifts.
        //
        // ⚠️ IT MUST NOT CANCEL THE TAP, and the two must not fight. A hold is
        // a tap that outstayed its welcome, so the recognizers overlap by
        // construction: `cancelsTouchesInView = false` keeps the rest of the
        // cell reachable, and the short duration is what separates "toggle" from
        // "hold" in the hand rather than in the code.
        //
        // Deliberately NOT a toggle. A hold has an end, and playback resumes at
        // it — which is why it reads as "look at this frame" rather than as a
        // second way to press pause. The pause glyph stays out of it for the
        // same reason: nothing was chosen, so nothing should be announced.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleMediaHold))
        hold.minimumPressDuration = MediaCarouselView.holdToPauseDuration
        hold.cancelsTouchesInView = false
        hold.delegate = self
        contentView.addGestureRecognizer(hold)

        // The glass card's swipe exit. TWO locks keep it strictly inside
        // the engagement lifecycle — this recognizer paralyzed the whole
        // feed when it had neither:
        // 1. DISABLED at rest (`setCommentsEngaged` is the one switch):
        //    a disabled pan cannot receive or claim touches, full stop —
        //    the pager-lock doctrine, applied to our own gesture. Without
        //    it the idle pan won every vertical drag from the pager (a
        //    subview's recognizer outranks the ancestor scroll's pan).
        // 2. DELEGATE-gated begin: the begin gate must live in the
        //    delegate callback, not only the UIView override — UIKit
        //    consults `gestureRecognizerShouldBegin` on the HIT-TESTED
        //    view, and feed touches hit deep subviews (media, chrome),
        //    so a cell-level override alone is unreliable as a gate.
        cardSwipeRecognizer.addTarget(self, action: #selector(handleCardSwipe))
        cardSwipeRecognizer.delegate = self
        cardSwipeRecognizer.isEnabled = false
        addGestureRecognizer(cardSwipeRecognizer)

        buildLayout()

        // The two halves of the collection readout meet here and nowhere else:
        // the card owns the pages, the chrome owns the indicator, and neither
        // reaches for the other.
        // The strip under the caption is drawn from the scroll itself, so it
        // gets the continuous signal; everything else here acts on a PAGE and
        // gets the discrete one below.
        mediaCard.onScrollPosition = { [weak self] position in
            self?.chrome.mediaStrip.setMediaScrollPosition(position)
        }
        mediaCard.onPageChanged = { [weak self] page in
            guard let self else { return }
            self.chrome.mediaStrip.setMediaPage(page)
            self.carouselPlayback.reconcilePagePlayback()
            // A page that is a clip draws the strip as its bar; one that is not
            // takes the bar away. Both are decided by what is under the viewer.
            self.updatePlayheadFeed()
            // A gallery's pages arrive one at a time, so turning to one is
            // exactly the moment the answer to "is there a picture here" can
            // change — in either direction.
            self.refreshMediaLoader()
            self.onMediaPageChanged?(page)
        }
        // The playback's outputs land on the chrome, and the chrome's scrub
        // lands on the playback: the bar and the clip meet here.
        playback.onPlayhead = { [weak self] fraction, seconds in
            guard let self else { return }
            chrome.mediaStrip.setMediaPlayhead(fraction, seconds: seconds)
            // A clip browsed onto may only start after the page turned: its
            // preview joins it as soon as it has a player.
            if mediaBrowse.isBrowsingMedia, mediaBrowse.browseMirrorPage != mediaCard.currentPage,
               mediaCard.videoPageIndices.contains(mediaCard.currentPage) { mediaBrowse.refreshBrowseMirror() }
        }
        playback.onLoading = { [weak self] loading in
            self?.chrome.mediaStrip.setMediaLoading(loading)
        }
        playback.onScrubPreviewLoading = { [weak self] loading in
            self?.chrome.mediaStrip.setScrubPreviewLoading(loading)
        }
        playback.onScrubPreviewPicture = { [weak self] image in
            self?.chrome.mediaStrip.setScrubPreviewPicture(image)
        }
        #if DEBUG
        playback.debugCurrentPage = { [weak self] in self?.mediaCard.currentPage ?? 0 }
        playback.debugPostID = { [weak self] in self?.representedID?.rawValue ?? "nil" }
        #endif
        chrome.mediaStrip.onScrubPreviewRequested = { [weak self] fraction in
            self?.playback.updateScrubPreview(fraction)
        }
        // A tap on the bar, exact — see `SnapCellPlayback.seek(toFraction:)`.
        // A drag seeks only at its release (`endScrub(at:)`, #2150).
        chrome.mediaStrip.onMediaSeekRequested = { [weak self] fraction in
            self?.playback.seek(toFraction: fraction)
        }
        chrome.mediaStrip.onMediaScrubBegan = { [weak self] in self?.playback.beginScrub() }
        chrome.mediaStrip.onMediaScrubEnded = { [weak self] fraction in self?.playback.endScrub(at: fraction) }
        // Browsing (#1734): the carousel jumps to the page under the finger,
        // and a clip landed on PLAYS at once — in the post and in its preview,
        // one player for both (the owner, 2026-10-25; `refreshBrowseMirror`).
        chrome.mediaStrip.onMediaBrowseBegan = { [weak self] in
            guard let self else { return }
            mediaBrowse.isBrowsingMedia = true
            mediaBrowse.refreshBrowseMirror()
        }
        chrome.mediaStrip.onMediaBrowse = { [weak self] page in
            guard let self else { return }
            mediaCard.setPage(page, animated: false)
            mediaBrowse.refreshBrowseMirror()
        }
        chrome.mediaStrip.onMediaBrowseEnded = { [weak self] page in
            guard let self else { return }
            mediaBrowse.isBrowsingMedia = false
            mediaBrowse.tearDownBrowseMirror()
            if mediaCard.currentPage != page { mediaCard.setPage(page, animated: false) }
            carouselPlayback.reconcilePagePlayback()
            updatePlayheadFeed()
        }
        chrome.mediaStrip.onMediaPageRequested = { [weak self] page in
            guard let self else { return }
            // ⚠️ A NEIGHBOUR IS A PAGE TURN; ANYTHING FURTHER IS A JUMP.
            //
            // This was a teleport for every distance while a FINGER asked for
            // the page — the scrubbing thumb is the clock, and a scroll
            // animation would have run a second one against it. The drag stopped
            // paging, so a tap asks now, and a tap has no clock: the carousel's
            // own motion is the only one left, and it is what makes the strip
            // reflow rather than cut.
            //
            // But an animation is a page TURNING, and one aimed six segments
            // away is not a turn — it is the six pictures in between thrown
            // past the viewer at a speed that makes them noise, to arrive
            // somewhere they could see from the start.
            //
            // ⚠️ SO THE JOURNEY IS NOT SHOWN AND THE ARRIVAL IS. The carousel
            // is put down next door to the target without a word, and then
            // turns the last page. Every tap ends in the same motion whatever
            // it was aimed at, which is the point: a rule that animated some
            // taps and cut others made the strip look broken on the ones it
            // cut — reported exactly that way, as "sometimes the resize does
            // not play".
            //
            // The silent step is a REAL page change and travels the normal
            // path, playback and loader included. That is not a concession: it
            // is the same run of events a fast swipe across those pages fires,
            // and a page the viewer is about to be one turn away from is one
            // the warm window wants anyway.
            let current = self.mediaCard.currentPage
            if abs(page - current) > 1 {
                self.mediaCard.setPage(page > current ? page - 1 : page + 1, animated: false)
            }
            self.mediaCard.setPage(page, animated: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        // ⚠️ THE PAGE'S OWN STAGE, and it is FRAME-MANAGED on purpose.
        //
        // Everything the page draws lives in here, so a transition that has to
        // move the page moves ONE view. The layers used to be transformed
        // individually — correct arithmetic, since a view transform is applied
        // about its own centre, and a permanent source of one-frame
        // disagreements: a layout pass, a spring in flight and a gesture event
        // are three different moments, and four layers being told the same
        // thing at three moments is four chances to be told late.
        //
        // It cannot be pinned by constraints. Auto Layout assigns FRAMES, and
        // assigning a frame to a transformed view re-derives its bounds and
        // centre from it — the transform is silently cancelled, which is what
        // happened to `contentView` and then to each layer in turn. So this one
        // is positioned by `bounds`/`center` in `layoutSubviews`, both of which
        // are transform-safe, and nothing else ever writes its geometry.
        pageStage.frame = contentView.bounds
        contentView.addSubview(pageStage)

        // ⚠️ A HAIRLINE AT EACH END, and it is not decoration.
        //
        // Every page here fills the screen edge to edge, so two of them in a
        // row have no boundary at all: a light text page followed by a light
        // text page reads as one surface that changed its mind, and a paging
        // gesture that lands halfway shows no seam to say so. One pixel of
        // black at the top and bottom is the whole of the answer — the pages
        // are separated by the same line the platform uses between anything
        // else, and it costs nothing to draw.
        //
        // On `contentView` rather than `pageStage`: the stage is transformed
        // by the engagement, and a separator that scaled with it would stop
        // being one pixel.
        for edge in [pageSeparatorTop, pageSeparatorBottom] {
            // ⚠️ NOT BLACK. A hard black line between two light pages is louder
            // than the boundary it marks — it reads as a border drawn around
            // the content rather than as the seam between two of them. The
            // platform's own separator is the right weight and follows the
            // theme, which matters here because the pages either side of it can
            // be light or dark independently.
            edge.backgroundColor = .separator
            edge.isUserInteractionEnabled = false
            edge.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(edge)
        }
        let hairline = 1 / (window?.screen.scale ?? UIScreen.main.scale)
        NSLayoutConstraint.activate([
            pageSeparatorTop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageSeparatorTop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageSeparatorTop.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageSeparatorTop.heightAnchor.constraint(equalToConstant: hairline),
            pageSeparatorBottom.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageSeparatorBottom.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageSeparatorBottom.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            pageSeparatorBottom.heightAnchor.constraint(equalToConstant: hairline)
        ])

        // Text-only posts' gradient page background lives inside the chrome
        // (shared with the hero flight's replica, so the landing swap can't
        // mismatch), not here. The media card hosts both render surfaces
        // full-bleed — in both states: it is the page at rest AND the
        // background of the engaged screen.
        mediaCard.pin(to: pageStage)

        // The header frost sits directly above the stream and below the
        // chrome: media → backdrop → stream → frost → chrome.
        // (Added after the container below.)
        // The comments region sits between the readability layer and the
        // chrome (whose rail floats over it). Constraints are minted at
        // install (they depend on the frozen insets). The comments stream:
        // FULL cell height, TRANSPARENT — its content rests below the card
        // via scroll inset and glides underneath it when scrolled, with the
        // post's own media visible behind every row. (This view was opaque
        // black until the background-media layout: that one colour was the
        // curtain that hid the post for the whole engagement.) No internal
        // header: the mutation itself says "comments".
        commentsContainer.backgroundColor = .clear
        // SQUARE and UNCLIPPED. A screen-matched corner was tried twice:
        // `containerConcentricRadius` resolves to ~0 for a view flush with
        // its container, and reading `UIScreen._displayCornerRadius` meant
        // private API for something that was visually inert anyway — the
        // container is transparent, so a radius only clips content, and no
        // content reaches those corners.
        headerFrost.isHidden = true
        headerFrost.translatesAutoresizingMaskIntoConstraints = false
        commentsContainer.isHidden = true
        commentsContainer.translatesAutoresizingMaskIntoConstraints = false
        pageStage.addSubview(commentsContainer)
        pageStage.addSubview(headerFrost)

        // ⚠️ ON THE STAGE (#1915): a grab moves the live page, its interface
        // included — the streams, the ticker, the wheel, the caption. Pinned to
        // `contentView` it stood still while the stage left.
        chrome.pin(to: pageStage)
        // The action column rides ABOVE the chrome (#695): the comments'
        // fade takes the chrome, never the like pill and the sound bubble.
        // In the stage's twin, so it moves with the page (#1917).
        columnStage.frame = contentView.bounds
        contentView.addSubview(columnStage)
        chrome.actionColumn.installActionColumn(in: columnStage)

        // NOTE: no pause glyph is installed here. The mark that says a clip is
        // stopped belongs to the PICTURE — `SnapMediaCardView` holds it for a
        // single attachment and each carousel page holds its own — so it rides
        // a swipe instead of hanging in the middle of the screen while the
        // pages move underneath it.
    }

    // MARK: - Comments engagement

    /// Installs the comments UI (a child controller's view, owned by the
    /// feed VC) into the region below the strip, settled and ready BEFORE
    /// the engagement animates: the container starts invisible with a
    /// small downward offset so the one spring block lifts it in with the
    /// rest of the mutation.
    func installComments(_ view: UIView) {
        commentsContainer.isHidden = false
        // Pure crossfade, no translation: the bottom band's geometry must
        // hold dead-still while the old footer and the composer swap.
        commentsContainer.alpha = 0
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        // FULL height: the stream spans the whole cell and slides under the
        // strip (the hosted scroll view rests its content below the strip
        // via inset — `setEngagedInsets` on the child).
        commentsContainerConstraints = [
            commentsContainer.topAnchor.constraint(equalTo: pageStage.topAnchor),
            commentsContainer.leadingAnchor.constraint(equalTo: pageStage.leadingAnchor),
            commentsContainer.trailingAnchor.constraint(equalTo: pageStage.trailingAnchor),
            commentsContainer.bottomAnchor.constraint(equalTo: pageStage.bottomAnchor),
        ]
        NSLayoutConstraint.activate(commentsContainerConstraints)
        // The header band spans EXACTLY its container — screen top to where
        // the stream's content begins — and ramps across all of it: opaque
        // at the screen's edge, fully clear at the container's inner edge.
        // Nothing spills past the chrome the band exists to serve.
        headerFrost.isHidden = false
        // The veil, on the pages where the blur alone cannot be seen.
        headerFrost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: mediaURL != nil))
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = [
            headerFrost.topAnchor.constraint(equalTo: pageStage.topAnchor),
            headerFrost.leadingAnchor.constraint(equalTo: pageStage.leadingAnchor),
            headerFrost.trailingAnchor.constraint(equalTo: pageStage.trailingAnchor),
            headerFrost.heightAnchor.constraint(
                equalToConstant: SnapCommentsLayout.commentsTopInset(topInset: frozenInsets.top)
            ),
        ]
        NSLayoutConstraint.activate(headerFrostConstraints)
        // NOTE: no caption card is installed here. The caption is the
        // hosted stream's FIRST ROW now, so it scrolls with the comments
        // instead of floating above them — which is what removed the
        // measured caption height, the reserved strip rectangle, and the
        // job of keeping a fixed card in sync with a moving list.
        // NOTE: the media card is NOT z-lifted here. It stays at the back
        // of the stack for the whole engagement — the stream reads over it
        // through the backdrop, which is the entire point of this layout.
        // (It used to be raised above the frost so the docked tile could
        // float over the comments; that lift is what made its invisible
        // full-bleed frame eat stream touches, and it is gone with the
        // tile.)
        view.translatesAutoresizingMaskIntoConstraints = false
        commentsContainer.addSubview(view)
        view.pin(to: commentsContainer)
        contentView.layoutIfNeeded()
    }

    /// **THE LIVE GRAB (#1915)**: the page follows the card as the engaged
    /// dismissal's does — one stage transform, under a window shaped like the
    /// card — with its whole interface on it, alive. Only the media leaves the
    /// page: the card carries it (the donated surface, still playing).
    ///
    /// - Nothing fades while the finger is down. On the release, a commit
    ///   fades the interface inside the release's spring, and a cancel
    ///   leaves it as it was (`setEngagedDismissal`).
    /// - The page takes no touch while held: the grab owns the finger.
    /// - The interface does not reflow under its transform: its insets are
    ///   the frozen ones (`applyChromeInsets`), never the stage's safe area.
    func beginLiveGrab() {
        guard !isEngagedDismissing else { return }
        isEngagedDismissing = true
        isLiveGrab = true
        // Alpha, never `isHidden`: a hidden surface stops feeding the card's
        // sibling surface (`beginEngagedDismissal`).
        alphaForMaskedReveal = mediaCard.alpha
        mediaCard.alpha = 0
        groundForMaskedReveal = contentView.backgroundColor
        contentView.backgroundColor = .clear
        restingAlphas = dismissalTravellers.map(\.alpha)
        stages.forEach { $0.isUserInteractionEnabled = false }
    }

    /// ⚠️ A PURE FUNCTION OF THE FINGER, never an animation.
    ///
    /// The grab can be pushed forward, dragged back and abandoned; anything
    /// that animated towards a target here would be chasing a value that has
    /// already moved, and a cancelled grab would leave the page mid-flight.
    /// The dim and the toolbar recede on exactly these terms. (The RELEASE is
    /// the exception, and it is not one: the same call is made from inside the
    /// release's own animation block, so UIKit interpolates it on the card's
    /// spring rather than on a second one.)
    func setEngagedDismissal(_ state: ZoomDismissState) {
        guard isEngagedDismissing else { return }
        let settling = state.isSettling
        let t = min(max(state.progress, 0), 1)
        // The thread and its wash recede together, on one value — each from
        // where it already was. The photograph is the card's and is not this
        // method's business at all — see `beginEngagedDismissal`.
        //
        // A live grab's interface does not recede under the finger (#1915):
        // it is the page, held. It fades only on the release's way home, in
        // its spring — `t` is 1 there, and 0 on a cancel's.
        let fade = isLiveGrab ? (settling ? t : 0) : t
        for (view, resting) in zip(dismissalTravellers, restingAlphas) {
            view.alpha = resting * (1 - fade)
        }
        guard state.card.width > 0, state.card.height > 0 else { return }
        // ⚠️ THE PAGE OVERHANGS THE CARD BY A HAIR, and this is the answer to a
        // light leak rather than a cosmetic tweak.
        //
        // Nothing here can be exact. The page FOLLOWS the card — told its rect
        // on a channel, applied a hop later, from another view hierarchy — and
        // a follower can be made arbitrarily close and never identical. (Being
        // a passenger inside the card would be exact, and is not available: the
        // thread is a hosted child controller's view, and UIKit throws
        // `UIViewControllerHierarchyInconsistency` the moment such a view is
        // moved out of its parent's hierarchy. Tried; it crashes on the first
        // grab.)
        //
        // What a fraction of a point exposed was a BRIGHT edge: inside the
        // window the card's photograph carries the page's wash, outside it the
        // card is undimmed, so any gap read as a sliver of light on a dark
        // page. So the page is drawn a little larger than the card it covers.
        // The error is still there and now falls the other way — a hair of wash
        // over the dimmed feed.
        //
        // ⚠️ HALF A POINT, AND ONLY WHILE THE FINGER IS DOWN.
        //
        // Two points was visible on both counts: the wash overhung the
        // photograph on all four sides, and a cancelled grab animated to a page
        // two points too large and then snapped to its real size when the
        // gesture was torn down. A bleed exists to swallow SUB-PIXEL error —
        // fractional rects, one rounding — and half a point is already three
        // device pixels. Anything a bleed would have to be to hide a real lag
        // is a bleed you can see.
        //
        // The release carries none: `settling` means the card is going to a
        // known rect and the page must arrive exactly there, so a cancelled
        // grab lands on its own size and the teardown has nothing to correct.
        let card = settling
            ? state.card
            : state.card.insetBy(dx: -Self.dismissalBleed, dy: -Self.dismissalBleed)
        // ⚠️ FILL, NOT FIT — and it moves the THREAD now, which is all that is
        // left to move.
        //
        // The arithmetic is kept because it is why the photograph is no longer
        // here. Three mappings were tried while the page still drew its own:
        // by WIDTH it ended a different shape from the card (`x=0.776 y=0.495`
        // at the release — 57% too tall); by BOTH AXES the frames agreed and
        // the image was squashed; FILL kept the ratio and still re-cropped,
        // because a crop of a crop is not the crop. Only removing the second
        // copy settles it.
        //
        // Fill stays for the thread: it keeps the text's proportions while the
        // window takes the overflow.
        let fill = max(
            card.width / max(contentView.bounds.width, 1),
            card.height / max(contentView.bounds.height, 1)
        )
        // ⚠️ ONE VIEW, ONE TRANSFORM. Everything the page draws is inside
        // `pageStage`, so the mapping is applied once, about one centre, in one
        // assignment — and a layout pass cannot erase it, because nothing but
        // this cell writes that view's geometry.
        //
        // It was a transform per layer before, which is correct arithmetic (a
        // view transform is applied about its own centre, so each needed its
        // own translation) and a permanent source of one-frame disagreements: a
        // layout pass, a spring in flight and a gesture event are three
        // different moments, and four layers told the same thing at three
        // moments is four chances to be told late.
        // ⚠️ TWO CHANNELS, BECAUSE THE CARD HAS TWO — and folding them into one
        // transform is what put the page BEHIND the card.
        //
        // The flight's grab drives the card's POSITION directly on every pan
        // event and its SIZE on a spring (the detach dip). A single affine
        // carrying both meant the page's position was animating toward a centre
        // the card had already left: told inside the dip's block, it chased a
        // moving target and lagged it by the whole of the dip. On screen that
        // is the comments and the wash sitting a few dozen points behind the
        // photograph — the same numbers, arriving late.
        //
        // So the page is decomposed exactly as the card is: the centre is
        // assigned, live, and only the scale is left to whatever animation is
        // in flight.
        // ⚠️ AND THE CENTRE IS ASSIGNED OUTSIDE ANY ANIMATION while the finger
        // is down. Inside the dip's block it animated like everything else, so
        // it was interpolating toward a position the card had already left —
        // measured trailing it by 7pt across and 12pt down at a tenth of the
        // gesture, which is the comments and the wash sitting visibly behind
        // the photograph. The release is the one time it should spring, and
        // that is what `settling` says.
        let centre = CGPoint(x: card.midX, y: card.midY)
        // ⚠️ A HELD STATE DROPS WHAT A RELEASE LEFT IN FLIGHT (#2362). A grab
        // during a cancel's spring catches the card where it is and says so
        // here, as a held state, mid-spring: the stages and the window still
        // carry the release's animations — additive ones on position and
        // transform, which would keep adding what they had left onto the
        // caught pose, the page parting from the card until the spring ended.
        // A held grab animates nothing here, so whatever is in flight is the
        // release's; a layer without animations costs a nil check.
        if !settling {
            stages.forEach { if $0.layer.animationKeys() != nil { $0.layer.removeAllAnimations() } }
            if let mask = flightMask, mask.layer.animationKeys() != nil { mask.layer.removeAllAnimations() }
        }
        if settling {
            stages.forEach { $0.center = centre }
        } else {
            UIView.performWithoutAnimation { stages.forEach { $0.center = centre } }
        }
        stages.forEach { $0.transform = CGAffineTransform(scaleX: fill, y: fill) }
        // ⚠️ THE CARD'S RADIUS, HANDED OVER — never a second copy of the curve.
        //
        // The window computed its own interpolation from the display's corner
        // to the row's, which is the right shape and was not the card's: the
        // card held the display's radius flat for the whole drag, so the two
        // silhouettes were rounded differently for the length of the gesture.
        // The card interpolates now (`grabCornerRadius`) and passes the number
        // it used, so there is one curve and no way to disagree about it.
        let window = flightMask ?? makeDismissalWindow()
        window.frame = card
        window.layer.cornerRadius = state.cornerRadius
        #if DEBUG
        if LaunchArgument.grabLog.isPassed() {
            // The two rects that must be the same rect: where the window is,
            // and where the page actually landed after its transform. A gap
            // between them is the gap on screen, and nothing else can be.
            // The card's PRESENTATION frame beside the page's, in the same
            // space — the only comparison that can catch one lagging the
            // other. Comparing the window's rect to the page's proved nothing:
            // both are derived from the same converted number in the same
            // breath, so they agreed while the card was somewhere else.
            print(String(format: "[grab] t=%.2f fill=%.3f card=%@ stage=%@",
                         t, fill, NSCoder.string(for: card),
                         NSCoder.string(for: pageStage.layer.presentation()?.frame
                                            ?? pageStage.frame)))
        }
        #endif
    }

    /// ⚠️ `bounds` AND `center`, NEVER `frame`.
    ///
    /// The stage carries the transition's transform, and assigning a frame to a
    /// transformed view re-derives its bounds and centre from that frame —
    /// which cancels the transform. Setting the two directly is the same
    /// geometry and leaves the transform alone, so a layout pass landing in the
    /// middle of a gesture costs nothing.
    override func layoutSubviews() {
        super.layoutSubviews()
        stages.forEach { $0.bounds = CGRect(origin: .zero, size: contentView.bounds.size) }
        // ⚠️ NOT WHILE A TRANSITION IS MOVING IT. The centre is one of the two
        // channels the grab drives (see `setEngagedDismissalProgress`), and a
        // layout pass re-centring the stage mid-gesture would drag the page
        // back to the middle of the screen between two events.
        guard !isEngagedDismissing else { return }
        stages.forEach { $0.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY) }
    }

    /// The views the grab moves and fades: the two stages, the whole page —
    /// its media already handed to the card (#1915).
    private var dismissalTravellers: [UIView] { stages }

    /// How far the page overhangs the card it covers. Small enough to be
    /// invisible where it spills, large enough to swallow a follower's error.
    private static let dismissalBleed: CGFloat = 0.5

    /// The dismissal's window, made on the first event that has a card to
    /// follow rather than at `begin` — a mask installed at a rect nobody has
    /// computed yet is a blank page.
    private func makeDismissalWindow() -> UIView {
        let mask = UIView()
        // Opaque: a mask reads its alpha channel, so a clear view masks
        // everything away — a blank screen rather than a clipped one.
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        contentView.mask = mask
        flightMask = mask
        return mask
    }

    /// Puts the page back, on either outcome. An abandoned grab returns to a
    /// page that must be exactly what it was.
    func endEngagedDismissal() {
        guard isEngagedDismissing else { return }
        isEngagedDismissing = false
        stages.forEach {
            $0.transform = .identity
            $0.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        }
        for (view, resting) in zip(dismissalTravellers, restingAlphas) {
            view.alpha = resting
        }
        restingAlphas = []
        if isLiveGrab {
            isLiveGrab = false
            stages.forEach { $0.isUserInteractionEnabled = true }
        }
        // The wash comes back with everything else: an abandoned grab returns
        // to a page that has to be readable again.
        contentView.mask = nil
        flightMask = nil
        mediaCard.alpha = alphaForMaskedReveal
        contentView.backgroundColor = groundForMaskedReveal
        groundForMaskedReveal = nil
    }

    /// The engaged stream's top inset — where its content rests, just
    /// below the screen chrome. A pure function of the safe area now: the
    /// caption scrolls inside the stream, so nothing above it has to be
    /// measured. The VC threads this into `setEngagedInsets`.
    func engagedCommentsTopInset(safeAreaTop: CGFloat) -> CGFloat {
        SnapCommentsLayout.commentsTopInset(topInset: safeAreaTop)
    }

    /// The engagement's INTERPOLATABLE state, as one function of progress:
    /// 0 = fully engaged, 1 = fully dismissed. Every leg that can be driven
    /// continuously lives here and nowhere else, which is what lets the
    /// finger-driven pull-down and the animated engage/disengage share one
    /// definition of what the two ends look like.
    ///
    /// (The blur bands and the bubble's glass are NOT here: a material
    /// materializes through the `effect` property, which has no fractional
    /// state. They switch at the ends and are hidden behind the fading
    /// stream while the drag is in flight.)
    func setCommentsEngagementProgress(_ progress: CGFloat) {
        let t = min(max(0, progress), 1)
        commentsContainer.alpha = 1 - t
        // NO transform here. The shrink belongs to the STREAM alone (the
        // hosted list scales itself), because the footer's blur band lives
        // inside this container and a band that scales stops sitting at the
        // screen's edge — it drifts inward and reads as part of the moving
        // layer instead of as fixed chrome.
        // The header band is a SIBLING, so it never scaled; it fades on its
        // own alpha to leave with everything else. (Alpha on an effect view
        // cannot MATERIALIZE a blur, which is why the band still switches
        // its `effect` at the ends — but fading an already-built one out is
        // exactly what alpha is for.)
        headerFrost.alpha = 1 - t
        // The page's own chrome returns as the stream leaves — the ticker
        // and caption fade back IN as the comments fade out, one crossfade
        // rather than two sequential ones.
        chrome.setCommentsEngagedProgress(t)
    }

    /// The ground this page owns, remembered so a transition-scoped tint can
    /// be handed back without re-deriving the format.
    private var restingGround: UIColor = .systemBackground
    /// A ground borrowed for the length of a reveal — the gallery card's own
    /// fill, so the page the mask opens onto starts as the card the viewer
    /// tapped rather than as a lighter rectangle where the card used to be.
    ///
    /// Set through `setRevealGroundTint` and cleared by handing back `nil`.
    /// Applied to `contentView`, which is the surface `configure` paints, so
    /// there is exactly one writer of this colour and the resting value is
    /// never lost.
    private var revealGroundTint: UIColor?

    /// Wears `color` as the page's ground, or hands the page's own back.
    ///
    /// `backgroundColor` is animatable, so calling this inside an animation
    /// block CROSS-FADES — which is the whole mechanism: the card's fill at
    /// the handshake, the page's own by the landing, on the same spring as
    /// the mask. It also scrubs, so a dismissal driven by a finger carries the
    /// tint back at the speed of the hand.
    func setRevealGroundTint(_ color: UIColor?) {
        revealGroundTint = color
        contentView.backgroundColor = color ?? restingGround
    }

    /// Reclaims the region after disengagement settles (the VC removes the
    /// child's view; this clears the cell-side scaffolding).
    /// Whether this cell is currently showing a comments panel.
    ///
    /// The one question a caller can ask about the DISPLAY without knowing how
    /// the panel got here — which is what a specification has to be written
    /// against, since every defect in this area has been a difference between
    /// the bookkeeping and the pixels.
    var isShowingComments: Bool {
        // ⚠️ AND VISIBLE. A panel is installed at alpha 0 and revealed by the
        // engagement, so a media page's parked tap-to-comments WARM is hosted
        // here too — present, and showing nothing. Counting it would make the
        // specification claim a media page displays a thread it does not.
        !commentsContainer.isHidden
            && commentsContainer.alpha > 0
            && !commentsContainer.subviews.isEmpty
    }

    func clearComments() {
        // The comments gone, the column unfolds onto the record (#1929).
        chrome.setSoundShowsReturn(false, animated: false)
        commentsContainer.subviews.forEach { $0.removeFromSuperview() }
        commentsContainer.isHidden = true
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        commentsContainerConstraints = []
        headerFrost.isHidden = true
        headerFrost.alpha = 1
        headerFrost.effect = nil
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = []
    }

    /// Applies or reverses the comments-engaged layout. Call inside a
    /// single `UIView.animate` spring block — every mutation here is
    /// animatable (the backdrop's dim and blur, the media's recede, chrome
    /// surface alphas, the card's glass and content), which is what keeps
    /// the whole state change ONE motion on ONE surface. The player is
    /// untouched by construction: nothing here re-hosts it, and after the
    /// dock's removal nothing here even moves its surfaces.
    /// A stand-in for the resting panel, shown at once (charter PR 5b): the
    /// same container, the same frost, the same engaged chrome, so the page
    /// looks as it will once the real panel is mounted over it.
    func installRestingPlaceholder(_ placeholder: UIView) {
        installComments(placeholder)
        // The engaged LOOK — container and frost up, backdrop dimmed, the
        // chrome's rail down — WITHOUT marking the cell engaged: the real
        // panel's mount goes through `installComments` (alpha 0) and then
        // `setCommentsEngaged(true)` to show it, and a cell already marked
        // engaged would skip that second step and leave both invisible. The
        // rail matters: with the look applied by hand the page flew in with
        // its reaction bubbles showing, which the real panel then hid.
        setCommentsEngagementProgress(0)
        if window != nil, headerFrost.effect == nil {
            headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    /// The real panel has been mounted above it: the stand-in fades and goes.
    func removeRestingPlaceholder(_ placeholder: UIView, animated: Bool = true) {
        guard placeholder.superview != nil else { return }
        if animated {
            placeholder.fadeOutSkeleton(removing: true)
        } else {
            placeholder.removeFromSuperview()
        }
    }

    func setCommentsEngaged(_ engaged: Bool) {
        guard engaged != isCommentsEngaged else { return }
        isCommentsEngaged = engaged
        // The card's page-drive pan exists ONLY while engaged — the state
        // seam is the recognizer's power switch, so no teardown path can
        // strand an armed pan in the default feed. Armed on EVERY engaged
        // post (media AND text): a vertical swipe on the card drives the
        // pager interactively, exactly like the composer bar's — it pages,
        // it never dismisses, so it's the right gesture on a text post's
        // permanent resting interface too.
        cardSwipeRecognizer.isEnabled = engaged

        if engaged {
            // One interpolatable set (see `setCommentsEngagementProgress`),
            // so the boolean legs and any driven one can never diverge.
            setCommentsEngagementProgress(0)
            // The band materializes on the same beat and the same supported
            // path (the `effect` property — alpha on an effect view is not,
            // which is also why the blur cannot ride the interactive drag).
            if window != nil, headerFrost.effect == nil {
                headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
            }
        } else {
            setCommentsEngagementProgress(1)
            headerFrost.effect = nil
        }
    }

    // MARK: - The comments sheet (#2087)

    /// The page under the comments sheet (#2087, #2521).
    private(set) lazy var commentsSheetPose = SnapCommentsSheetPose(host: self)

    // MARK: - Configuration

    func configure(
        with model: FeedItemDisplayModel,
        pipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?,
        initialMediaPage: Int? = nil
    ) {
        representedID = model.id
        mediaURL = model.mediaURL
        mediaKind = model.mediaKind
        self.videoPlayback = videoPlayback
        chrome.configure(with: model)
        chrome.setImagePipeline(pipeline)
        chrome.onCommentsTapped = { [weak self] in
            guard let self, let id = self.representedID, !self.isCommentsEngaged else { return }
            self.onRequestComments?(id)
        }
        chrome.onReactionsRunningLow = { [weak self] in
            guard let self, let id = self.representedID else { return }
            self.onReactionsRunningLow?(id)
        }
        chrome.onBoostRequested = { [weak self] spend in
            guard let self, let id = self.representedID else { return }
            self.onRequestBoost?(id, spend)
        }
        chrome.onBoostUndoRequested = { [weak self] in
            guard let self, let id = self.representedID else { return }
            self.onRequestBoostUndo?(id)
        }
        chrome.actionColumn.onSoundSheetRequested = { [weak self] in self?.onRequestSoundSheet?() }
        chrome.actionColumn.onSoundReturnRequested = { [weak self] in self?.onRequestSoundReturn?() }
        chrome.actionColumn.onShareRequested = { [weak self] in self?.onRequestShare?() }
        #if DEBUG
        // Which projection fields are present the moment the page is
        // configured. Everything listed here is supposed to render at 0ms from
        // the grid's own projection; anything reported missing is arriving on a
        // later fetch and is what "instant metadata" is actually waiting on.
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[media] %.3f page CONFIGURE author=%@ caption=%@ avatar=%@ audio=%@ likes=%@ age=%@",
                         CACurrentMediaTime(),
                         model.authorName.isEmpty ? "MISSING" : "yes",
                         model.caption?.isEmpty == false ? "yes" : "MISSING",
                         model.avatarURL == nil ? "MISSING" : "yes",
                         model.audioText?.isEmpty == false ? "yes" : "n/a",
                         model.likeCount > 0 ? "\(model.likeCount)" : "0",
                         model.timestampText.isEmpty ? "MISSING" : "yes"))
        }
        #endif
        let hasMedia = model.mediaURL != nil
        #if DEBUG
        // `-media-audit`: every page that configures WITHOUT a media payload,
        // and under `-rich-media` whether that is by design.
        //
        // The distinction this exists to draw: a text-only post rendering as a
        // coloured page is the product working, while a MEDIA post arriving
        // with no URL — or with one that never resolves — is a pipeline
        // failure, and the two are indistinguishable on screen. Both look like
        // "a solid colour where a photo should be".
        if LaunchArgument.mediaAudit.isPassed() {
            let rich = LaunchArgument.richMedia.isPassed()
            if !hasMedia {
                print("[media-audit] \(model.id.rawValue) NO MEDIA PAYLOAD"
                      + " kind=\(model.mediaKind) rich=\(rich)"
                      + " caption=\(model.caption?.isEmpty == false ? "yes" : "no")")
            } else {
                print(String(
                    format: "[media-audit] %.3f %@ media kind=%@ pages=%d url=%@",
                    CACurrentMediaTime(), model.id.rawValue, "\(model.mediaKind)",
                    model.mediaPages.count, model.mediaURL?.absoluteString ?? "-"
                ))
            }
        }
        #endif
        // THE PAGE'S GROUND. A media page is black because black is what
        // letterboxing should be — the surface exists to disappear behind a
        // photo. A TEXT page has nothing to disappear behind, so its ground
        // is the page itself and it follows the system appearance.
        restingGround = hasMedia ? .black : .systemBackground
        contentView.backgroundColor = revealGroundTint ?? restingGround
        // …and the page's THEME, applied once at the root of everything the
        // cell owns: the frost band, and the whole comment panel hosted
        // inside it. Both inherit from here rather than deciding for
        // themselves, which is what keeps them from disagreeing (see
        // `SnapChromeTheme`). The screen's bars live outside this tree and
        // are set from the same rule in `SnapFeedViewController`.
        pageHasMedia = hasMedia
        applyPageTheme()
        // Composition is POSITIONAL now (the info card's frame is set at
        // install per `hasMedia`), so the info card itself is format-
        // agnostic — its caption always starts at its own inner padding.

        // The media card selects its surface for the kind and clears any
        // prior frame; a text post's surface simply never receives content.
        mediaCard.configure(kind: hasMedia ? model.mediaKind : .image, hasMedia: hasMedia)
        // The shape the post declares, which frames the page (`SnapMediaAspect`)
        // until the picture arrives and can be measured — and which is all a
        // hero has to compose with on a cold open.
        mediaCard.setDeclaredAspect(model.headAspectRatio.map { CGSize(width: $0, height: 1) })
        // ⚠️ ARMED HERE, ABOVE THE COLLECTION'S EARLY RETURN.
        //
        // It was armed after the single-media loads at the bottom, and a
        // collection never reaches them: `showCollection` returns, so a gallery
        // — the format most likely to be waiting on a download, since it has
        // several — was the one format that never said it was waiting. Caught
        // in the simulator, not by the suite: the specs build single-media
        // pages, and every one of them passed.
        //
        // A CLIP'S POSTER IS NOT ITS MEDIA, which is the other half: the
        // photograph waits with nothing on screen, the clip waits behind a
        // still standing in for a video that has not started. The first decoded
        // frame retires it either way.
        // ⚠️ ON THE CARD, NOT ON `mediaCard.renderView`. The surface under this
        // page is re-pointed by every landing, every reclaim and every carousel
        // page turn; a closure installed on the object that happens to be there
        // at bind is stranded by all three. See
        // `SnapMediaCardView.onPictureAvailabilityChange`.
        mediaCard.onPictureAvailabilityChange = { [weak self] _ in
            self?.refreshMediaLoader()
        }
        // And the bone coming or going (#1505): while it stands, the wait is
        // its to say.
        mediaCard.onPictureLoadingChange = { [weak self] in
            self?.refreshMediaLoader()
        }
        refreshMediaLoader()

        let isVideo = hasMedia && model.mediaKind == .video
        let isImage = hasMedia && model.mediaKind == .image

        // A COLLECTION replaces the single photo surface with its pages, and
        // returns before the single-media loads below: those fill a surface the
        // carousel has just hidden, and the work would be a download per page
        // that nothing draws.
        if model.isCollection {
            mediaCard.showCollection(
                model.mediaPages, imagePipeline: pipeline,
                headAspect: model.headAspectRatio.map { CGSize(width: $0, height: 1) }
            )
            // Without animation: this is where the page OPENS, not a move the
            // viewer made, and an animated jump would read as the carousel
            // scrolling by itself the moment the flight lands.
            // AFTER `showCollection`, and only when one was asked for: the
            // carousel keeps its page across a re-configure with the same pages,
            // so a second configure carrying no instruction must not be read as
            // an instruction to go back to the first.
            if let initialMediaPage { mediaCard.setPage(initialMediaPage, animated: false) }
            chrome.setMediaPageCount(
                model.mediaPages.count,
                current: mediaCard.currentPage,
                clipPages: Set(mediaCard.videoPageIndices)
            )
            chrome.mediaStrip.setMediaPreviews(
                thumbnails: model.mediaPages.map(\.thumbnailURL),
                videoPages: Set(mediaCard.videoPageIndices), pipeline: pipeline
            )
            updatePlayheadFeed()
            #if DEBUG
            // ⚠️ Published HERE as well as from the window, because the window
            // only runs once the page is active or the viewer has moved — so a
            // post sitting on page one, untouched, had no probe at all, and a UI
            // test read that absence as "no collection here". The state it
            // reports is the true one either way: nothing retained yet.
            if let videoPlayback { carouselPlayback.publishRetentionProbe(pool: videoPlayback) }
            #endif
            #if DEBUG
            // ⚠️ Both halves on one line: what was ASKED and where the carousel
            // ENDED UP. A sender that says nothing and a receiver that stays are
            // each behaving correctly on their own — the defect only exists
            // between them, so only a line that shows both can name it.
            if CarouselPlaybackAudit.isEnabled {
                print("[sync] post asked=\(initialMediaPage.map(String.init) ?? "-")"
                      + " landed=\(mediaCard.currentPage)")
            }
            #endif
            // ⚠️ Opening ON a clip is not a page CHANGE, so nothing above would
            // start it. A post opened from a card already showing page three
            // lands on page three; if that page is a video it has to play from
            // the moment it arrives, exactly as a single-video post does.
            if isActive { carouselPlayback.reconcilePagePlayback() }
            return
        }
        // A cell rebound from a collection to a single attachment without going
        // through reuse would otherwise keep the old post's clips alive behind
        // a hidden carousel.
        for view in mediaCard.releaseRetainedSurfaces() {
            videoPlayback?.stop(view)
        }
        mediaCard.hideCollection()
        // A lone CLIP still has a position to report — where you are in it — so
        // the strip is drawn for one page and becomes that clip's bar. A lone
        // photograph reports nothing and keeps no strip.
        chrome.setMediaPageCount(isVideo ? 1 : 0, current: 0, clipPages: isVideo ? [0] : [])
        chrome.mediaStrip.setMediaPreviews(thumbnails: [], videoPages: [], pipeline: nil)
        updatePlayheadFeed()

        if isImage {
            loadImage(model.mediaURL, expecting: model.id, pipeline: pipeline)
        } else if isVideo, let thumbnailURL = model.thumbnailURL {
            // The poster, shown under the player until the first frame is
            // ready (or while an asset is still processing). Cache hit applied
            // SYNCHRONOUSLY — see `loadImage` for why the async hop is what
            // the viewer sees as a gap.
            mediaCard.loadPicture(thumbnailURL, kind: .video, pipeline: pipeline)
        } else {
            mediaCard.cancelPicture()
        }
        refreshMediaLoader()
    }

    /// Freezes the chrome's layout bounds to the SCREEN's header/footer
    /// thresholds (the feed view's safe-area insets — nav bar bottom,
    /// toolbar top) instead of the cell's ambient safe area. Cells move
    /// during page transitions and ambient insets re-derive every frame;
    /// the pushed thresholds hold still, so the interaction zone (caption,
    /// ticker, subtitle, shortcut rail) rides the page with structurally
    /// accurate bounds. Same doctrine as the flight replica's captured
    /// insets — one chrome scaffold, one inset authority.

    func applyChromeInsets(_ insets: UIEdgeInsets) {
        frozenInsets = insets
        chrome.setFixedInsets(insets)
    }

    /// Hands the post's comment streams to the chrome's two surfaces (the
    /// band's queue, the subtitle zone's cues). Arrives from the view model
    /// whenever loaded — before or after this cell becomes visible; each
    /// surface starts once both its content and the visibility gate are in
    /// place.
    func updateCommentStreams(_ streams: FeedViewModel.CommentStreams) {
        #if DEBUG
        // The async half. `isLoaded=false` is the known-zero flag, so a first
        // delivery with it false is the placeholder and the real one follows.
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[media] %.3f page STREAMS loaded=%@ reactions=%d subtitles=%d count=%d",
                         CACurrentMediaTime(), streams.isLoaded ? "yes" : "NO",
                         streams.reactions.count, streams.subtitles.count, streams.commentCount))
        }
        #endif
        chrome.updateCommentStreams(streams)
        // The info card's comment metric rides the same seam (and the
        // same known-zero honesty flag) as the chrome's surfaces.
    }

    /// Visibility-scoped comment-surface control, driven by the view
    /// controller's `willDisplay`/`didEndDisplaying`: both surfaces render
    /// on any on-screen page, including one being dragged in, unlike
    /// playback which stays on the settle-quantized active seam.
    func setTickerStreaming(_ streaming: Bool) {
        chrome.commentSurfaces.setTickerActive(streaming)
        // The subtitle zone rides the same visibility seam: a page dragged
        // partway in slides in with its pill already rendered (the
        // persistent cue is static content between handoffs, like the
        // caption), instead of popping in after settle.
        chrome.setSubtitlesActive(streaming)
    }

    private func loadImage(_ url: URL?, expecting id: PostID, pipeline: ImagePipeline) {
        guard let url else {
            mediaCard.cancelPicture()
            return
        }
        // A cache hit is applied SYNCHRONOUSLY, in the same turn as the
        // `configure` that just cleared the old image.
        //
        // This is the ~1200ms black window on image posts. `configure` nils the
        // image so a recycled cell can never show the previous post's photo —
        // which is correct — and every re-supply then went through a `Task`,
        // even when the image was already in memory. The card's black floor is
        // what filled that hop, and re-entering a post you had just been
        // looking at showed photo, black, the SAME photo.
        //
        // Deferring the nil-out instead would close the gap by showing the
        // OUTGOING post's photo on the incoming page — a wrong image rather
        // than no image, which in a paging feed is the worse failure. Reading
        // the cache first has neither: the correct photo, no gap. It is also
        // what `PostGridTileCell.configure` has always done; only the feed
        // went straight to the async path.
        //
        // A genuine cache miss still loads asynchronously, behind the bone
        // (#1505). That is a first load with nothing to display yet, which is
        // a different thing from blanking something we already had.
        mediaCard.loadPicture(url, kind: .image, pipeline: pipeline) {
            // A post that HAS a media URL and cannot load it leaves the card
            // on its floor — visually identical to a text page, and silent
            // until now. This is the failure the audit is for.
            #if DEBUG
            if LaunchArgument.mediaAudit.isPassed() {
                print("[media-audit] \(id.rawValue) IMAGE LOAD FAILED url=\(url.absoluteString)")
            }
            #endif
        }
    }

    // MARK: - SnapCellLifecycle

    func willBecomeActive() {
        guard !isActive else { return }
        isActive = true
        defer { updatePlayheadFeed() }
        // Activation always starts playing, so any user-paused glyph is stale.
        setPauseGlyphVisible(false)
        // Normally redundant with the visibility path (`setTickerStreaming`),
        // but it is the restart edge after backgrounding: foregrounding
        // re-activates the settled page without a fresh `willDisplay`.
        // Both comment surfaces share it.
        chrome.commentSurfaces.setTickerActive(!isPostUnavailable)
        chrome.setSubtitlesActive(!isPostUnavailable)
        // Nothing of a post the viewer may no longer see plays (#1409).
        guard !isPostUnavailable else { return }
        clipStart.startOnActivation()
    }

    // MARK: - The wait

    /// Whether the page is announcing a wait — see `SnapMediaWait`, which
    /// asks `showsAPicture` and drives the card's centred loader.
    ///
    /// ⚠️ THE OWNER'S RULE (2026-10-27), TikTok's: a full-screen media that has
    /// not arrived loads under a loader at the centre; a clip whose STREAM is
    /// buffering — its poster or frames already up — says so with the bar's
    /// pulse (`SnapCellPlayback.onLoading`, #1537), never a loader over it.
    private(set) lazy var mediaWait: SnapMediaWait = {
        let wait = SnapMediaWait(
            hasItsOwnMedia: { [weak self] in self?.showsAPicture ?? true },
            isShowingLoader: { [weak self] in self?.mediaCard.isShowingLoader ?? false },
            setLoading: { [weak self] loading in self?.mediaCard.setLoading(loading) }
        )
        #if DEBUG
        wait.debugSubject = { [weak self] in self?.mediaURL?.lastPathComponent ?? "nil" }
        #endif
        return wait
    }()

    /// Whether the media area shows a picture of the post — the photograph,
    /// a clip's poster or frames, a page's cover: what the centred loader
    /// waits for. A clip with its poster up is NOT waited on here; its stream
    /// is the bar's to announce.
    private var showsAPicture: Bool {
        guard mediaURL != nil else { return true }
        // A picture that failed for good shows its failure mark and Try Again
        // instead (#1767): nothing left for the loader to wait on.
        return mediaCard.showsPicture || mediaCard.isPictureFailed
    }

    /// Re-decides whether the page is announcing a wait — called from every
    /// place the answer can change (`SnapMediaWait.refresh`).
    func refreshMediaLoader() {
        mediaWait.refresh()
    }

    /// Drops the wait entirely — the recycle path.
    private func cancelMediaLoader() {
        mediaWait.cancel()
    }

    // MARK: - Viewport playback

    /// The clip's start, pause and stop, its playhead feed and the occlusion (#2521).
    private(set) lazy var clipStart = SnapPageClipStart(host: self)

    // MARK: - Hero-flight live media

    /// The hero flight's handoff of the clip (#2521). The zoom destination,
    /// the screen and the tests ask the page; each answer is the handoff's.
    private(set) lazy var flightHandoff = SnapFlightHandoff(host: self)
    var defersPlaybackForFlight: Bool {
        get { flightHandoff.defersPlaybackForFlight }
        set { flightHandoff.defersPlaybackForFlight = newValue }
    }
    func revealWarmAttachedSurface() -> Bool { flightHandoff.revealWarmAttachedSurface() }
    func startDeferredPlayback() { flightHandoff.startDeferredPlayback() }
    var isMediaContentRendering: Bool { flightHandoff.isMediaContentRendering }
    @discardableResult func parkPlayback() -> Bool { flightHandoff.parkPlayback() }
    func donateLiveRenderView() -> VideoRenderView? { flightHandoff.donateLiveRenderView() }
    static func keepsOwnSurface(incomingHasFrame: Bool, ownIsShowing: Bool) -> Bool {
        SnapFlightHandoff.keepsOwnSurface(incomingHasFrame: incomingHasFrame, ownIsShowing: ownIsShowing)
    }
    func adoptLiveRenderView(_ view: VideoRenderView) { flightHandoff.adoptLiveRenderView(view) }
    func reclaimDonatedPlayback(_ view: VideoRenderView) { flightHandoff.reclaimDonatedPlayback(view) }
    func mirrorPlayback(to surface: VideoRenderView) -> Bool { flightHandoff.mirrorPlayback(to: surface) }
    func reclaimPlayback() { flightHandoff.reclaimPlayback() }
    func releasePlaybackForDeparture() { flightHandoff.releasePlaybackForDeparture() }

    // MARK: - Play/pause toggle

    /// Begin-time gate for the card's swipe exit, the composer bar's
    /// mechanism verbatim: engaged only, vertical intent only (the
    /// dominant velocity axis at begin time), and born anywhere inside
    /// the floating glass card's territory (slightly expanded for thumb
    /// forgiveness). Scoped to the card pan — every other recognizer
    /// keeps UIKit's default.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === cardSwipeRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard isCommentsEngaged else { return false }
        let velocity = cardSwipeRecognizer.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return cardSwipeRegionContains(cardSwipeRecognizer.location(in: contentView))
    }

    /// The page-drive swipe's territory: the HEADER BAND — everything above
    /// where the stream's content begins.
    ///
    /// It used to be the floating caption card. With the caption scrolling
    /// as a list row there is no non-scrolling card left to grab, and the
    /// band above the stream is the only cell territory a drag can start in
    /// without fighting the list: below this line a vertical drag scrolls
    /// the comments, which is exactly what it should do. Internal (not
    /// private) so the boundary stays unit-testable.
    func cardSwipeRegionContains(_ point: CGPoint) -> Bool {
        guard point.y >= 0 else { return false }
        return point.y <= SnapCommentsLayout.commentsTopInset(topInset: frozenInsets.top)
    }

    /// A vertical swipe on the glass card drives the feed pager
    /// INTERACTIVELY (same as the composer bar's page-swipe). The whole
    /// engaged layer — docked media card, glass, comments — lives inside
    /// THIS cell, so once the host hand-moves the pager's `contentOffset`
    /// the entire assembly rides the finger for free; the cell only
    /// forwards the pan's phase + raw translation/velocity. No self-nudge
    /// (that would double the motion), no commit-only settle.
    @objc private func handleCardSwipe(_ pan: UIPanGestureRecognizer) {
        guard isCommentsEngaged else { return }
        let dy = pan.translation(in: self).y
        let vy = pan.velocity(in: self).y
        switch pan.state {
        case .began:
            onRequestCommentsPageDrive?(.began, 0, 0)
        case .changed:
            onRequestCommentsPageDrive?(.changed, dy, vy)
        case .ended, .cancelled, .failed:
            onRequestCommentsPageDrive?(.ended, dy, vy)
        default:
            break
        }
    }

    /// What a tap or a hold on the page means (#2521).
    private(set) lazy var mediaTaps = SnapMediaTapArbiter(host: self)

    @objc private func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        mediaTaps.tapMedia(at: recognizer.location(in: contentView))
    }

    @objc private func handleMediaHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            mediaTaps.beginMediaHold(at: recognizer.location(in: contentView))
        case .ended, .cancelled, .failed:
            mediaTaps.endMediaHold()
        default:
            break
        }
    }

    /// Pauses the clip while a sheet covers it — the sound sheet's preview
    /// playing, or a feed opened from its grid (never the sheet's detent
    /// alone) — and resumes it after, but only if it was running when
    /// covered: a clip the viewer had paused stays paused.
    func setCoveredBySheet(_ covered: Bool) {
        guard videoPlayback != nil, let surface = audibleSurface else { return }
        // Uncovered while the page is no longer the playing one (the sheet
        // expanded meanwhile, #1914): the resume owed is forgotten, not paid.
        if !covered, !isActive {
            playback.forgetSheetPause()
            return
        }
        playback.setCovered(covered, on: surface)
    }

    /// See `SnapPageClipStart.updatePlayheadFeed`.
    func updatePlayheadFeed() { clipStart.updatePlayheadFeed() }

    // MARK: - Paging and chrome, for the transitions

    // ⚠️ OUTSIDE THE FENCE BELOW, and they were inside it by accident.
    //
    // The `#if DEBUG` was added around a run of test affordances, and it
    // landed in the middle of one member's doc comment — orphaning that doc
    // and swallowing four members that a transition calls on every ordinary
    // dismissal. Nothing caught it because CI builds Debug only, so the app
    // simply did not compile for Release.
    //
    // The convention the fence already follows is the check: everything that
    // belongs in it is named `debug…`. These four are not.

    /// Holds the page's own chrome back while a flight's REPLICA stands in for
    /// it, then brings it in.
    ///
    /// ⚠️ The replica exists precisely so the real chrome need not be visible in
    /// the air. It was anyway — nothing ever hid it — so the card simply lifted
    /// off a fully drawn page, and at the landing the replica vanished and the
    /// real thing was revealed on one frame. That is the pop: not something
    /// appearing, but something that had been there all along stopping being
    /// covered.
    /// A reveal has landed: the band enters now (see the ticker).
    func replayCommentBandEntrance() {
        chrome.commentSurfaces.replayCommentBandEntrance()
    }

    func setChromeHeldForFlight(_ held: Bool) {
        isChromeHeldForFlight = held
        defer { clipStart.refreshPersonOcclusion() }
        chrome.commentSurfaces.setTickerHeldForFlight(held)
        // The column leaves and returns with the hold, engaged or not: the
        // replica flies its own (#695).
        chrome.actionColumn.setColumnHeld(held)
        if held {
            chrome.alpha = 0
            return
        }
        guard chrome.alpha < 1 else { return }
        // ⚠️ NOT WHEN THE COMMENTS ALREADY OWN THE CHROME.
        //
        // `chrome` is one of the engagement's own fade layers: engaged, it is
        // deliberately at zero. This restore is unconditional — it exists to
        // undo the HOLD, and it wrote the same property — so a post opened
        // straight into its thread landed wearing both interfaces at once, the
        // ticker and the caption and the page dots sitting under a comment
        // stream.
        //
        // The hold's opposite is not "visible", it is "whatever the page was
        // doing before it was covered".
        guard !isCommentsEngaged else { return }
        // ⚠️ NOT A FADE. The flight's replica carries this page's whole
        // chrome — caption, rail, bar, header — fully drawn, so a chrome
        // that fades in from zero when the replica goes is two frames of
        // nothing and then a copy of what was there coming back: a flash
        // (filmed 25 September 2026, the first time the hold reached a
        // tapped page). What the replica did NOT carry enters on its own:
        // the band through the ticker's release above, the pill here.
        chrome.alpha = 1
        chrome.commentSurfaces.replaySubtitleEntrance()
    }

    /// The page indicator's scrub, so the screen can make its dismissal yield.
    var mediaScrubGesture: UIGestureRecognizer { chrome.mediaStrip.mediaScrubGesture }
    /// The caption's slide, which drives the strip on a post with one (#2269).
    var captionSlideGesture: UIGestureRecognizer { chrome.captionSlide }

    /// Moves an ALREADY CONFIGURED page's collection to `page`.
    ///
    /// The twin of `configure(initialMediaPage:)`, for the case that has no
    /// configure to ride: this screen is reused, so a post opened a second time
    /// arrives at a cell that is already built and already sitting on the page
    /// the viewer left it on. See `SnapFeedViewController.openMediaPage`.
    func showMediaPage(_ page: Int) {
        mediaCard.setPage(page, animated: false)
    }

    /// Which page a DISMISSAL is leaving from, or nil when this post is not a
    /// collection at all.
    ///
    /// The mirror of `showMediaPage`, and it exists for the same reason that
    /// one does: the card a close flies carries the page the viewer is looking
    /// at, so the row it lands on has to be showing that page and not the first
    /// one. Nil rather than zero — "this post has no pages" and "this post is
    /// on its first page" are different answers, and only one of them means
    /// "leave the row alone".
    var currentMediaPage: Int? {
        mediaCard.showsCollection ? mediaCard.currentPage : nil
    }

    /// How the picture in front of the viewer is framed, the shape that
    /// decided it, and the backdrop drawn around it — what a hero flying to or
    /// from this page composes (`SnapFeedViewController.zoomPageFraming`). Nil
    /// for a text page, which has no picture.
    var pictureFraming: (framing: MediaFraming, aspect: CGSize?, backdrop: UIImage?)? {
        guard pageHasMedia else { return nil }
        return (mediaCard.currentFraming, mediaCard.currentFramingAspect, mediaCard.currentBackdrop)
    }

    /// Toggles the active video's playback and reflects it in the pause glyph.
    /// No-op for image/text cells (no player).
    /// Whether the page's own player can be paused — a clip; a photo or text
    /// page's song is the feed's (#1148).
    var canTogglePlayback: Bool { playsVideo && !isPostUnavailable }

    /// Toggles the clip. `markOnPage`: the stopped mark on the picture, as
    /// a tap on it shows; false when it is drawn elsewhere — the side list's
    /// tile (#1550). Returns whether the clip is now paused.
    @discardableResult
    func togglePlayback(markOnPage: Bool = true) -> Bool? {
        guard canTogglePlayback, let paused = playback.toggle() else { return nil }
        setPauseGlyphVisible(markOnPage && paused)
        return paused
    }

    /// The stopped mark on the picture, shown or taken down from outside —
    /// the side list hands it over as it opens and back as it closes.
    func setPausedMarkVisible(_ visible: Bool, animated: Bool = true) {
        mediaCard.setPausedMark(visible, animated: animated)
    }

    /// The mark's share while the side list carries it to the tile (#1580).
    func setPausedMarkShare(_ share: CGFloat) {
        mediaCard.setPausedMarkShare(share)
    }

    /// The picture's stopped mark's opacity, nil when it wears none. Tests.
    var debugPausedMarkAlpha: CGFloat? { mediaCard.visiblePausedMark?.alpha }

    /// Whether the picture wears the stopped mark.
    var showsPausedMark: Bool { mediaCard.showsPausedMark }

    /// Puts the stopped mark on the picture in front of the viewer, or takes it
    /// away. The card decides WHERE that is — its own bounds for a single
    /// attachment, the current page for a collection.
    func setPauseGlyphVisible(_ visible: Bool) {
        mediaCard.setPausedMark(visible)
    }

    /// The still this page is actually drawing — the picture a presenter's
    /// flight home has to dissolve away when the viewer is leaving from HERE
    /// rather than from the post that opened the feed.
    ///
    /// Read off the rendered surface rather than re-derived from the model, for
    /// the same reason `currentMediaPage` is: a post with a carousel is showing
    /// one of several pictures, and only the surface knows which. Nil for a
    /// text page, which has no picture to hand over.
    var currentPageCover: UIImage? { mediaCard.renderedStill }

    /// Whether this page is the active one, for the lifecycle.
    var isLifecycleActive: Bool { isActive }

    /// Steps down as the active page WITHOUT touching its clip (#1580): the
    /// items are being swapped under the post on show, and the page that
    /// shows it next adopts this very player (`SnapFeedViewController
    /// .handOverReorderedPlayback`) — stopped here, it restarted.
    ///
    /// ⚠️ **NOR ITS COMMENT SURFACES (#1798).** They stood down here, and the
    /// swap usually hands the post back to THIS cell: its band stopped and
    /// laid a new train, a cut, a dark beat and a fade-in, and its subtitle
    /// pill moved to another cue in the same frame, at every opening and
    /// closing of the side list (the owner's recording). They keep running;
    /// the hand-over stands them down only when another cell shows the post
    /// (`standDownCommentSurfaces`).
    func resignKeepingPlayback() {
        guard isActive else { return }
        isActive = false
        updatePlayheadFeed()
        carouselPlayback.cancelPrewarming()
    }

    /// The band and the subtitle pill stop: this cell no longer shows the
    /// post it kept them running for through a swap (#1798).
    func standDownCommentSurfaces() {
        chrome.commentSurfaces.setTickerActive(false)
        chrome.setSubtitlesActive(false)
    }

    func didResignActive(releasingPlayback: Bool) {
        guard isActive else { return }
        isActive = false
        updatePlayheadFeed()
        // The same rule the carousel applies to a page that leaves the box, at
        // the scale of the whole post: this page is not the one being watched
        // any more, so the receipt for a stop the viewer made on it has nothing
        // left to annotate. Coming back starts the clip regardless.
        mediaCard.clearPausedMarks()
        // Covers the paths visibility can't see: backgrounding and the
        // feed's own disappearance, where no `didEndDisplaying` fires.
        chrome.commentSurfaces.setTickerActive(false)
        chrome.setSubtitlesActive(false)
        clipStart.stopOnResign(releasingPlayback: releasingPlayback)
    }

    /// See `SnapCellLifecycle.releaseRetainedNeighbourClips` (`SnapCarouselPlayback`).
    func releaseRetainedNeighbourClips() { carouselPlayback.releaseRetainedNeighbourClips() }

    /// Re-asserts the engaged layout after the screen re-appears from an
    /// outbound push, so the pass reads settled coordinates, not a
    /// mid-transition hierarchy. Idempotent.
    func reassertEngagedGeometry() {
        guard isCommentsEngaged else { return }
        contentView.layoutIfNeeded()
    }

    /// Which theme this page draws in, resolved against the DEVICE rather than
    /// against the screen — see `SnapChromeTheme.style(hasMedia:device:)`.
    ///
    /// Re-applied when the cell joins a window because that is the first moment
    /// the device's style is knowable: a cell dequeued in `cellForItemAt` has no
    /// window yet, and a text page that resolved its theme before then took the
    /// screen's pin instead.
    private(set) var pageHasMedia = false
    /// The one-pixel seam between one full-screen page and the next — see the
    /// note where they are added.
    private let pageSeparatorTop = UIView()
    private let pageSeparatorBottom = UIView()

    private func applyPageTheme() {
        contentView.overrideUserInterfaceStyle = SnapChromeTheme.style(
            hasMedia: pageHasMedia,
            device: window?.traitCollection.userInterfaceStyle ?? .unspecified
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observeDeviceAppearance()
        applyPageTheme()
    }

    /// The window this cell listens to for the DEVICE's appearance, and the
    /// registration to take back when it leaves it.
    ///
    /// ⚠️ A TEXT PAGE'S THEME IS AN EXPLICIT STYLE, SO NOTHING UPDATES IT FOR
    /// FREE. `applyPageTheme` writes the device's style as it was at the
    /// moment it ran — `.light`, say — and an explicit override is exactly
    /// what stops a later trait change from reaching the subtree: switching
    /// the phone to dark left the page's ground and every label in its panel
    /// light until the feed was closed and reopened. It cannot be
    /// `.unspecified` instead (see `SnapChromeTheme.style(hasMedia:device:)`:
    /// the screen above pins itself dark over a photograph), and the cell's
    /// OWN traits never hear the device while the screen is pinned. The
    /// window is the one place the device's style arrives unpinned, so the
    /// page listens there.
    private lazy var deviceAppearance = SnapWindowAppearanceWatch { [weak self] in self?.applyPageTheme() }

    private func observeDeviceAppearance() {
        deviceAppearance.observe(window)
    }

    /// The side list's pose (#1509): the page's overlay — caption, ticker,
    /// like column, progress — moved down by the band the bottom toolbar
    /// covers, which a card between the bars shows empty. The media stays.
    func setSideListOverlayOffset(_ offset: CGFloat) {
        chrome.setOverlayOffset(offset)
    }

    /// The overlay's offset now. Tests.
    var sideListOverlayOffset: CGFloat { chrome.transform.ty }

    override func prepareForReuse() {
        super.prepareForReuse()
        mediaBrowse.isBrowsingMedia = false
        mediaBrowse.tearDownBrowseMirror()
        setSideListOverlayOffset(0)
        // A frozen carousel never goes on to another post (#1738): the next
        // display takes the screen's freeze state again.
        setCarouselScrollEnabled(true)
        isActive = false
        // A recycled cell owns nothing: the next post to land here is told
        // whether it has the screen, and a stale `true` would make that
        // message a no-op — the page would never start.
        clipStart.ownsViewport = false
        cancelMediaLoader()
        // ⚠️ AN UNFINISHED DISMISSAL OR MASKED REVEAL ENDS HERE (#788).
        //
        // Both are put back only by the feed's own `end…` calls, and a cell
        // can be recycled before they come: the next post then arrived with
        // its media at alpha 0 or hidden, under a leftover mask, and with the
        // flags still set, so the next `begin…` declined to run. Ended first,
        // while still engaged, the way the feed would have ended them — and
        // then the media is put back to a fresh page's own values, because
        // what either restores was captured from a page that no longer exists.
        endEngagedDismissal()
        // The reveal's spring may still be carrying the stage to identity, and
        // a released dismissal's spring may still be fading the layers it
        // drives: neither may play out on the next post.
        stages.forEach { $0.layer.removeAllAnimations() }
        dismissalTravellers.forEach { $0.layer.removeAllAnimations() }
        mediaCard.isHidden = false
        mediaCard.alpha = 1
        // Instant (unanimated) disengage: a recycled cell must come back
        // full-bleed. Ordered before the media/chrome resets it restores.
        setCommentsEngaged(false)
        clearComments()
        onRequestComments = nil
        onReactionsRunningLow = nil
        mediaTaps.onPostTrackTap = nil
        mediaTaps.onPostTrackHold = nil
        onRequestBoost = nil
        onRequestBoostUndo = nil
        onRequestCommentsPageDrive = nil
        // EVERY page's mark, not just the one showing: a recycled cell that
        // kept one on page three would put a stopped clip's receipt on a
        // picture belonging to a different post.
        mediaCard.clearPausedMarks()
        playback.reset()
        clipStart.stopPlayheadFeed()
        // ⚠️ A held chrome must never ride a recycled cell. A flight that is
        // cancelled, or a dismissal that ends the page instead of landing it,
        // leaves the hold un-released — and the next post to use this cell would
        // arrive with no chrome at all and nothing on the way to bring it back.
        chrome.alpha = 1
        chrome.actionColumn.setColumnHeld(false)
        // The next post to land here is told whether it is still available.
        setPostUnavailable(false)
        carouselPlayback.cancelPrewarming()
        // A swiped-past page keeps its paused player until its cell is reused:
        // this is where −1 (or +1, after a swipe back) is handed to the feed's
        // lookahead instead of being retired, when it wants that clip (#895).
        videoPlayback?.stop(mediaCard.renderView, keepingLookahead: true)
        // Reuse is the other door out, and a retained clip must not walk
        // through it into the next post.
        for view in mediaCard.releaseRetainedSurfaces() {
            videoPlayback?.stop(view)
        }
        representedID = nil
        flightMediaStartTime = nil
        mediaURL = nil
        mediaKind = .image
        // Back to the media ground AND the media theme: a recycled cell is a
        // media page until its next `configure` says otherwise, and a text
        // page's adaptive ground flashing behind an incoming photo is
        // exactly the kind of stranded state reuse produces.
        contentView.backgroundColor = .black
        contentView.overrideUserInterfaceStyle = SnapChromeTheme.style(hasMedia: true)
        mediaCard.cancelPicture()
        chrome.reset()
        mediaCard.setImage(nil)
        mediaCard.setPoster(nil)
    }
}

/// Marker class for the engaged comments region — the pager's per-touch
/// arbitration (`SnapFeedCell` hosts it, the feed VC's `claimsTouches`
/// consults it) declines drags born inside it, exactly the shortcut
/// rail's mechanism: inside the container the inner comments list
/// scrolls; outside it (the strip, the margins) the feed's paging takes
/// the touch.
final class SnapCommentsContainerView: UIView {}

extension SnapFeedCell {
    /// Keyboard-up hit arbitration: the risen composer's trailing ✕ lands
    /// inside the action rail's column, and the rail — interactive chrome
    /// layered ABOVE the comments container — would win those taps by
    /// z-order alone. While engaged, wherever the RAIL would take a touch,
    /// the container gets right of first refusal: if its own hit-test
    /// resolves to the composer at that point, the composer wins. The rail
    /// keeps every touch the composer doesn't physically overlap.
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        #if DEBUG
        if isCommentsEngaged, LaunchArgument.gestureLog.isPassed() {
            let chain = hit.map {
                sequence(first: $0, next: { $0.superview })
                    .prefix(8).map { "\(type(of: $0))(\(Int($0.frame.minY)))" }
                    .joined(separator: "<-")
            } ?? "nil"
            let bar = commentsContainer.subviews.first.map { child in
                child.subviews.compactMap { $0 as? CommentsInputBar }.first
                    .map { "barFrame=\($0.frame)" } ?? "no-bar-in-child"
            } ?? "no-child"
            print("GESTURELOG: cell hit at \(point) chain=\(chain) \(bar)")
        }
        #endif
        guard isCommentsEngaged, let hit else { return hit }
        // NOTE: the docked-media hit clip that used to live here is gone
        // with the dock. It existed because the crop mask trimmed PIXELS
        // and not hit-testing: the docked surface kept its full-bleed frame
        // under the uniform scale, so a z-lifted video tile ate stream
        // touches ~65pt above and below the visible square (an avatar tap
        // on the first comment row dismissed the whole engagement). The
        // media is neither transformed nor z-lifted now — it sits at the
        // back of the stack, beneath the stream — so the stream simply wins
        // its own touches by z-order and there is nothing to clip.
        // NOTE: the composer-vs-rail arbitration that used to live here is
        // gone too. The engaged composer rose into the shortcut rail's
        // column, and since the rail survived the engagement, every touch
        // in the overlap had to be re-routed to the bar by hand. The
        // engagement fades the rail out now — and UIKit does not hit-test a
        // view under alpha 0.01 — so there is no overlap left to referee.
        return hit
    }
}

// MARK: - Tap arbitration

extension SnapFeedCell: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The card's exit pan takes every touch it's offered — its own
        // begin-time gate (region + vertical intent + engagement) is the
        // filter, and it must see touches born on the card's metric
        // buttons too ("drag anywhere on the card").
        if gestureRecognizer === cardSwipeRecognizer { return true }
        // While engaged, the COMMENTS ZONE is tap-inert for the background
        // gesture: a touch landing anywhere in the hosted stream (rows,
        // gaps, the composer's band) must never collapse the engagement —
        // the explicit exits are the ✕, the strip zone, and the swipe
        // gestures. (The stream's own interactions — scrolling, row
        // controls, the composer — are untouched: declining the CELL's
        // tap takes nothing from views that own their touches.)
        if isCommentsEngaged,
           Self.isCommentsStreamTouch(touch.view, stopAt: contentView) {
            return false
        }
        return !Self.isInteractiveTouch(touch.view, interactiveRoots: chrome.interactionRoots, stopAt: contentView)
    }

    /// True when the touched view lives inside the engaged comments
    /// container — the zone where a tap means "interact with the stream",
    /// never "close the layout". Pure + static so the boundary is
    /// unit-testable, like `isInteractiveTouch`.
    static func isCommentsStreamTouch(_ touched: UIView?, stopAt: UIView) -> Bool {
        var view = touched
        while let current = view {
            if current is SnapCommentsContainerView { return true }
            if current === stopAt { break }
            view = current.superview
        }
        return false
    }

    /// True when the touched view is (or descends from) an interactive control —
    /// a `UIControl`, or any of `interactiveRoots` — walking up to `stopAt`. So
    /// taps on interactive chrome use those controls; taps on the background/
    /// media/caption toggle playback. Pure + static so the arbitration is
    /// unit-testable.
    static func isInteractiveTouch(_ touched: UIView?, interactiveRoots: [UIView], stopAt: UIView) -> Bool {
        var view = touched
        while let current = view {
            if current is UIControl { return true }
            if interactiveRoots.contains(where: { $0 === current }) { return true }
            if current === stopAt { break }
            view = current.superview
        }
        return false
    }
}

extension SnapFeedCell: SnapCommentsSheetPoseHost {}

extension SnapFeedCell: SnapCarouselPlaybackHost {}

extension SnapFeedCell: SnapBrowseMirrorHost {}

extension SnapFeedCell: SnapUnavailableBlockHost {}

extension SnapFeedCell: SnapMediaTapArbiterHost {}

extension SnapFeedCell: SnapPageClipStartHost {}
