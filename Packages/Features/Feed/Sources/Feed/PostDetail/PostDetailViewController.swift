import AuthInterface
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import MediaCore
import DesignSystem
import FeedInterface
import PostSurfaces
import ProfileInterface
import ThreadKit
import UIKit

final class PostDetailViewController: UIViewController {
    let viewModel: PostDetailViewModel
    let imagePipeline: ImagePipeline
    /// A TEXT post's resting comments: the threads grouped under pinned day
    /// pills (Recent order only), and the long press lifting the row into its
    /// menu. False for the media pages' comment panels, where nothing below
    /// runs and each row keeps its own menu.
    let threadChrome: Bool
    /// The threads grouped under a day chip each, in Recent order (#757):
    /// every snap page's comments — media and text — not only a text page's.
    let groupsByDay: Bool
    /// Builds the composer avatar's profile switcher menu. Nil wherever the
    /// app wires none — the face is then a plain, inert identity.
    private let profileSwitcher: (any ProfileSwitcherPresenting)?
    /// The app's viewer channel (#2376), for profile switches made ANYWHERE —
    /// this composer's menu, or the profile header while the comments sit
    /// open underneath — and for a change of viewer. Nil (tests): neither is
    /// heard.
    private let viewerEvents: ViewerEvents?
    /// The composer avatar's profile switcher and the viewer channel's two
    /// subscriptions (`PostDetailViewerSwitch`). Built on first use;
    /// building it does nothing else.
    private(set) lazy var viewerSwitch = PostDetailViewerSwitch(
        host: self, profileSwitcher: profileSwitcher, viewerEvents: viewerEvents
    )

    // MARK: - The two streams (#2007)

    /// The post's comments by the server's ranking (`CommentStream.Kind`):
    /// the tab a panel opens on, once the post has enough comments to rank
    /// (`CommentSortPolicy`; the owner, 2026-11-01).
    private(set) lazy var popular = CommentStream(host: self, kind: .popular)
    /// The post's comments as a conversation — the only stream below the
    /// threshold.
    private(set) lazy var recent = CommentStream(host: self, kind: .recent)
    /// Every stream the panel holds.
    var streams: [CommentStream] { [popular, recent] }
    /// The pager's pages: Popular first, the default (#2007).
    static let popularPage = 0
    static let recentPage = 1

    /// The two streams side by side, swiped between (#2007). Each keeps its
    /// own position; a switch moves them horizontally and nothing else.
    /// Paging is off — Recent alone — until there is a Popular tab.
    private lazy var pager: HorizontalPagerView = {
        let pager = HorizontalPagerView(
            pages: [popularPageView, recent.pageView],
            initialIndex: showsPopular ? Self.popularPage : Self.recentPage
        )
        // A drag past either end is the page's (the side list, the grab):
        // the pager claims only the drags that change its tab (#2008).
        pager.yieldsPastEnds = true
        pager.isPagingEnabled = showsPopular
        if showsPopular { mountPopular() }
        pager.onSettled = { [weak self] _ in self?.visibleStreamDidChange() }
        pager.onProgress = { [weak self] progress in self?.onStreamProgress?(progress) }
        return pager
    }()

    /// Popular's page: empty, and off the hierarchy's work, until there is a
    /// Popular tab — no bones shimmering where nobody can go.
    private let popularPageView = UIView()

    private func mountPopular() {
        guard popular.pageView.superview == nil else { return }
        popular.pageView.pin(to: popularPageView)
    }

    /// The stream on screen.
    var stream: CommentStream {
        guard showsPopular, isViewLoaded else { return showsPopular ? popular : recent }
        return pager.activeIndex == Self.popularPage ? popular : recent
    }

    /// What moves and hides as one: the streams.
    var streamSurface: UIView { pager }

    /// Whether the post has a Popular tab: its count reached the threshold —
    /// the opener's, or Recent's. Once there, it stays for the panel's life.
    private(set) var showsPopular = false

    /// Whether the tab the panel opens on is decided: Popular came, or the
    /// reader scrolled or changed tabs. Until then, Popular arriving — the
    /// opener's count, or a first page past the threshold after a preview of
    /// a few — opens on it; after, it leaves the reader where they are.
    private var hasChosenOpeningTab = false

    /// The reader scrolled a stream: the opening tab is theirs now.
    func readerDidScroll() { hasChosenOpeningTab = true }

    /// The pager's fractional position — 0 Popular, 1 Recent — for the
    /// selector that follows it.
    var onStreamProgress: ((CGFloat) -> Void)?
    /// The tab on screen settled.
    var onVisibleStreamChange: ((CommentStream.Kind) -> Void)?

    /// The visible tab: Popular or Recent.
    var visibleStreamKind: CommentStream.Kind { stream.kind }

    /// Shows `kind`'s tab — a selector's tap.
    func showStream(_ kind: CommentStream.Kind, animated: Bool) {
        guard showsPopular else { return }
        hasChosenOpeningTab = true
        let page = kind == .popular ? Self.popularPage : Self.recentPage
        let changes = pager.activeIndex != page
        pager.setActivePage(page, animated: animated)
        // An unanimated page change settles off the pager's scroll, which a
        // pager not laid out yet never runs: told here, once.
        if !animated, changes, lastSettledStream !== stream { visibleStreamDidChange() }
    }

    /// The stream `visibleStreamDidChange` last announced.
    private weak var lastSettledStream: CommentStream?

    /// The pager, for a selector that scrubs it.
    var streamPager: HorizontalPagerView { pager }

    // MARK: - The streams cut to their room (#2298)

    /// Whether the streams read in the panel's room (#2298, the owner
    /// 2026-11-11): Popular shows the caption and the whole threads that fit
    /// between the bar and the composer, then "See all n comments"; Recent
    /// loads its older pages only on its "Earlier comments" row. On the text
    /// page in a vertical feed (`setEngagedPageSwipeHandler`) and in the
    /// comments sheet (`SnapCommentsSheetViewController.prepare`); elsewhere
    /// (the published text post's sheet) both scroll through all they hold
    /// and page as the reader nears an end, as before.
    private(set) var cutsStreamsToRoom = false

    /// Turns `cutsStreamsToRoom` on, for good.
    func cutStreamsToRoom() {
        guard !cutsStreamsToRoom else { return }
        cutsStreamsToRoom = true
        guard isViewLoaded else { return }
        streams.filter(\.hasAppliedStream).forEach { $0.applyStream(animated: false) }
    }

    /// Popular's "See all n comments": Recent, as a tap on its tab would
    /// show it — the pager's own change, the selector following (#2298).
    func seeAllComments() {
        showStream(.recent, animated: !MotionPreference.reducesMotion)
    }

    /// The post's comment count, as well as the panel knows it: the opener's,
    /// or what Recent holds once it holds more. Nil when neither knows.
    var postCommentCount: Int64? {
        let held = Int64(commentCount)
        guard let known = knownCommentCount ?? seededCardMetrics?.comments else { return held > 0 ? held : nil }
        return max(known, held)
    }

    /// THE CAPTION ROW'S AUTHOR FACE, bound by the screen hosting the panel
    /// (#2300). A text page's author is its caption's row — the chrome's
    /// author row shows only on a media page — so that face is one more of
    /// the feed's `AuthorBadgeBinding` faces: its relation mark, its "+", its
    /// tap and hold. Called with the caption's cell at every configure, and
    /// at once for one already on screen. Nil (a media page's sheet, a pushed
    /// post): the face stays bare and its tap pushes the profile.
    var bindCaptionAuthor: ((CaptionBubbleCell) -> Void)? {
        didSet {
            guard isViewLoaded else { return }
            streams.forEach { $0.rebindCaptionAuthor() }
        }
    }

    /// The count reached the threshold: the Popular tab comes in. Opened on
    /// it when the opening tab is still to choose.
    private func popularBecameAvailable() {
        // A showcase has no comments to rank (#2216), nor a draft — the text
        // composer counts its zero comments, which is no threshold now (#2287).
        guard !showsPopular, takesComments, !viewModel.isDraft else { return }
        showsPopular = true
        let opensOnPopular = !hasChosenOpeningTab
        hasChosenOpeningTab = true
        guard isViewLoaded else { return }
        mountPopular()
        pager.isPagingEnabled = true
        viewModel.loadPopularIfNeeded()
        if opensOnPopular { showStream(.popular, animated: false) }
    }

    /// Recent counted its comments.
    private func recentDidCount(_ count: Int) {
        if CommentSortPolicy.isAvailable(commentCount: count) { popularBecameAvailable() }
    }

    /// The tab on screen changed: the way back, the day under the bar and the
    /// pull-down follow it.
    private func visibleStreamDidChange() {
        guard lastSettledStream !== stream else { return }
        lastSettledStream = stream
        applyRailWayBack()
        onScrollAwayChange?(stream.showsScrollAwayReturn)
        syncDayUnderHeader()
        sheetEdges.streamDidChange()
        onVisibleStreamChange?(stream.kind)
    }

    /// The comments sheet's edges and the streams' clip at the composer
    /// (`PostDetailSheetEdges`). Built on first use; building it does
    /// nothing else.
    private(set) lazy var sheetEdges = PostDetailSheetEdges(host: self)
    func letSheetTakeShortStreams() { sheetEdges.letSheetTakeShortStreams() }
    func wearSheetEdges() { sheetEdges.wearSheetEdges() }
    func setStreamsClippedAtComposer(_ clipped: Bool, below: CGFloat = 0) {
        sheetEdges.setStreamsClippedAtComposer(clipped, below: below)
    }

    /// The panel's height for its visible stream as laid out — the engaged
    /// top, the rows, the composer's band: whether the comments outgrow the
    /// comments sheet, which offers its expanded detent for them (#2087; the
    /// sheet's own height is its media's shape's since #2195). Nil before the
    /// stream has rows or engaged insets.
    var fittedHeight: CGFloat? {
        guard let engaged = engagedStreamInsets else { return nil }
        let rows = stream.collectionView.contentSize.height
        guard rows > 0 else { return nil }
        return engaged.top + rows + engaged.bottom
    }

    /// Whether Recent rides the keyboard, as a conversation does (#2007).
    /// Not in the comments sheet (#2087): UIKit raises the sheet itself over
    /// the keyboard, and Recent riding it too was pinned to its tail then
    /// clamped back, inside the keyboard's animation — the rows slid under
    /// the bar and back (measured, 2026-11-03).
    var streamsRideKeyboard = true

    // MARK: - The stream, as the panel's

    // What a host asks of the panel's list (each documented on `CommentStream`).
    var streamIsAtTop: Bool { stream.streamIsAtTop }
    var streamIsAtBottom: Bool { stream.streamIsAtBottom }
    func setStreamScrollEnabled(_ enabled: Bool) { streams.forEach { $0.setStreamScrollEnabled(enabled) } }
    var bottomAnchorSlack: CGFloat { stream.bottomAnchorSlack }
    func scrollToStart(animated: Bool) { stream.scrollToStart(animated: animated) }
    func revealCaptionAnchor(in space: UICoordinateSpace) -> CGRect? { stream.revealCaptionAnchor(in: space) }
    func revealVisibleComments() { stream.revealVisibleComments() }
    func viewHeightShowingEmptyPage(contentSizeCategory: UIContentSizeCategory) -> CGFloat? {
        stream.viewHeightShowingEmptyPage(contentSizeCategory: contentSizeCategory)
    }
    func scrollToDay(_ day: Date, animated: Bool = true) {
        #if DEBUG
        debugOnScrollToDay?(day)
        #endif
        recent.scrollToDay(day, animated: animated)
    }
    var debugStreamDays: [(day: Date, section: Int)] { recent.debugStreamDays }
    #if DEBUG
    var debugPlayedArrivals: [String] { stream.debugPlayedArrivals }
    var debugLandingEvents: [String] { stream.debugLandingEvents }
    #endif

    /// A failed first load, with its way out (#797).
    private let statusView = EmptyStateView()

    /// The one composer (#2308), on the comments' contract
    /// (`ComposerConfiguration.comments`, its default): a voice comment
    /// where the source carries one (#2309, `commentsVoice`), no
    /// attachments, the post's column. The sheet declares no column
    /// (`setComposerBare`); a text post's draft declares a voice post's
    /// voice (`TextPostComposerViewController`) until it is published.
    let composeBar = CommentsInputBar()

    private var composeBottomDefault: NSLayoutConstraint?
    private var composeBottomEngaged: [NSLayoutConstraint] = []
    /// **The action column (`SnapActionColumn`).** The engaged composer
    /// stands its stake and rail slot ON the media layout's like and repost
    /// bubbles — same size, same screen coordinates — so opening and closing
    /// the comments crossfades two bubbles that never move. The slot wears
    /// the post's sound (`publishedRailFace`); the composer's own bubble —
    /// the emote button, the send over a draft — stands beside it, on the
    /// row (#2308).
    ///
    /// - AT REST the bar's input row sits on the toolbar like every composer's
    ///   (`SnapActionColumn.inputRestingGap`) and the bar lifts its column to
    ///   the column's line; its trailing edge is the column's inset from the
    ///   screen's (not `lg`); the entrance is alpha only — no
    ///   micro-translation.
    /// - KEYBOARD UP the bar does NOT move: only its input row rides the
    ///   keyboard's top, `sm` above it, widening into the column's width as it
    ///   rises (`CommentsInputBar.riseWithKeyboard(of:)`). The column's bubbles
    ///   hold the media layout's coordinates under the keyboard (asked
    ///   2026-10-02).
    /// The stream's bottom when not engaged: the composer's top, or the risen
    /// input row's — whichever is higher (`configureViews`).
    private var scrollBottomDefault: [NSLayoutConstraint] = []
    private var scrollBottomEngaged: NSLayoutConstraint?
    /// The engaged footer's frost: rows gliding behind the composer stay
    /// visible but dissolve into a LIGHT blur, so the bar reads over them
    /// without the band reading as an overlay on the post. Clear at the
    /// band's top edge, full material at the screen's bottom — the header
    /// band's ramp, mirrored, and no `topRampLength`: that parameter exists to
    /// finish a ramp EARLY and hold it, which is exactly the plateau this
    /// stopped having. HIT-INERT: it must never eat the bar's taps or the
    /// swipe pan. Effect nil until the engaged entrance IN A WINDOW; it rides
    /// the master spring via `setComposerEntranceState`.
    private let composerBackdrop = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.footerFrostMaskColors,
        maskLocations: SnapCommentsLayout.footerFrostMaskLocations
    )
    /// The post as last rendered — the caption row's model, kept so a
    /// snapshot re-apply can rebuild item #0 without a refetch.
    var latestPost: PostDetailDisplayModel?
    /// The caption the opener already had, used until this screen's own post
    /// load returns.
    ///
    /// The caption row is the stream's first item and it existed only once the
    /// POST had loaded — which is a network round trip after the panel mounts.
    /// For a hero flight that is far too late: the row the card is supposed to
    /// land its caption ON did not exist while the card was in the air, so the
    /// flight had no target and the caption appeared as a second one when the
    /// post arrived.
    var seededCaption: (text: String, timestamp: String)?
    /// The seeded caption's voice (#2207): a voice post's row opens speaking.
    var seededVoice: PostVoice?
    /// The seeded caption's card (#2216): a showcase's row opens with it, and
    /// its page with no comments.
    var seededEmbed: PostEmbed?
    /// Whether the post takes comments (#2216): a channel's showcase takes
    /// none — no comment stream, no input row; its like and Share stay in
    /// the composer's column.
    private(set) var takesComments = true
    /// The post's comment count from the opener, before the fetch: the
    /// stream draws no more bones than that — none for zero (#1773).
    var knownCommentCount: Int64?
    /// The caption row's face and metric line, from the surface that opened
    /// this page. Survives hydration: a `FeedEntry` knows the format but not
    /// the view or comment counts, so the seed stays the source for the line
    /// (see `CaptionBubbleCell.configure`).
    var seededCardMetrics: PostCardMetrics?
    /// The author the opener handed over, so a seeded row wears its NAME and
    /// its avatar from frame one rather than an empty disc and a blank header
    /// until the fetch lands. The row names its author now (it is shaped like a
    /// comment), so the name is as load-bearing as the picture.
    var seededAuthor: (name: String, monogram: String, avatarURL: URL?)?
    /// Parents whose full reply pool is shown (the "view more" seam's
    /// state). Per-screen, like scroll position.
    var expandedReplyParents: Set<String> = []
    /// The armed reply target: the THREAD PARENT's id (replying to a reply
    /// binds to its top-level parent — comment.v1's two-depth contract)
    /// plus the tapped author's name for the placeholder.
    private(set) var replyTarget: (parentID: String, name: String)?
    /// The viewer's point balance, handed to the composer's boost.
    private let wallet: (any WalletStaking)?
    /// The composer's boost: the stake, its toast, the session undo and the
    /// wallet's observation (`PostDetailComposerBoost`). Built on first use;
    /// building it does nothing else.
    private(set) lazy var boost = PostDetailComposerBoost(host: self, wallet: wallet)

    init(
        viewModel: PostDetailViewModel,
        imagePipeline: ImagePipeline,
        profileSwitcher: (any ProfileSwitcherPresenting)? = nil,
        wallet: (any WalletStaking)? = nil,
        viewerEvents: ViewerEvents? = nil,
        threadChrome: Bool = false,
        groupsByDay: Bool = false
    ) {
        self.viewerEvents = viewerEvents
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.threadChrome = threadChrome
        self.groupsByDay = threadChrome || groupsByDay
        self.profileSwitcher = profileSwitcher
        self.wallet = wallet
        // A post's panel has its two tabs from birth (#2287: no threshold),
        // so it is BUILT on Popular — the pager's first page, mounted — and
        // never shows Recent first, waiting for a count. A draft (the text
        // composer) has no comments to rank until it is published; a
        // showcase gives its tabs back (`setTakesComments`).
        self.showsPopular = !viewModel.isDraft
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Leaving the post's comments — popped, dismissed, or inside a page or
    /// sheet that is — keeps a locked or paused voice comment for the
    /// session (#2309, the conversation's rule, #2102): opened again, it
    /// shows paused. A screen pushed over them leaves the take where it is.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let leaving = sequence(first: self as UIViewController, next: \.parent).contains {
            $0.isMovingFromParent || $0.isBeingDismissed || $0.navigationController?.isBeingDismissed == true
        }
        if leaving { voiceComposer?.leave() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        boost.commitUnlessToastIsUp()
    }

    /// Rows re-measure on a genuine WIDTH change — rotation, iPad size
    /// classes. Nothing here touches the empty page's HEIGHT: that is
    /// resolved once at configuration time and deliberately never revisited
    /// per layout, because a height that changes after frame 0 is the jump.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        streams.forEach { $0.remeasureStreamOnWidthChange() }
        refitEmptyPageOnHeightChange()
        syncDayUnderHeader()
        // Rows realised as the engaged stream grows into its room (#1799).
        let rise = streamsRideKeyboard ? composerRise : 0
        streams.forEach {
            // Popular's cut once its room is known, or changed (#2298).
            $0.refitCut()
            $0.syncBottomAnchor()
            $0.syncKeyboardRise(rise)
            $0.keepRestingEnd()
        }
        sheetEdges.syncStreamsClip()
    }

    /// How far the keyboard holds the composer's input row above the bar's
    /// resting top: the room Recent gives up to ride it (#2007). Read off the
    /// solved layout, as a conversation reads it.
    private var composerRise: CGFloat {
        guard composerTracksKeyboard, engagedStreamInsets != nil, !composeBar.isHidden else { return 0 }
        return max(0, composeBar.frame.minY - composeBar.occupiedMinY)
    }

    /// This view's height as last laid out — see `refitEmptyPageOnHeightChange`.
    private var lastLaidOutHeight: CGFloat = 0

    /// The empty page fills the room the stream has, and a SHEET changes that
    /// room without changing the width: moving between its detents. Re-fitted
    /// on a genuine change of THIS view's height — never per layout, and never
    /// for the stream's own growth during an engagement, which moves the
    /// collection view inside a view that stays put (`availableStreamHeight`).
    private func refitEmptyPageOnHeightChange() {
        let height = view.bounds.height
        guard height > 0, abs(height - lastLaidOutHeight) > 0.5 else { return }
        let isFirst = lastLaidOutHeight == 0
        lastLaidOutHeight = height
        guard !isFirst else { return }
        streams.forEach { $0.refitEmptyPage() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Comments"
        view.backgroundColor = .systemBackground
        configureViews()
        rail.installRailWayBack()
        // The snap feed's comments panel stands its stake bubble on the media
        // layout's like button: the same heart, badge and menu (#668).
        composeBar.usesLikeFace = true
        pushComposerLikeCount()
        if viewModel.isDraft { configureDraft() }
        voiceComments.installCommentVoice()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onEngagementChange = { [weak self] state in self?.renderEngagement(state) }
        viewModel.onCommentsChange = { [weak self] state in self?.recent.renderComments(state) }
        viewModel.onPopularCommentsChange = { [weak self] state in self?.popular.renderComments(state) }
        viewModel.onOlderCommentsLoadChange = { [weak self] _ in self?.recent.syncLinkRows() }
        viewModel.onComposingChange = { [weak self] composing in self?.renderComposing(composing) }
        viewModel.onViewerIdentityChange = { [weak self] identity in
            guard let self else { return }
            composeBar.setViewerIdentity(identity, imagePipeline: imagePipeline)
            // A DRAFT's composer names who the post will be BY: a switch
            // before publishing changes the author, not just the commenter.
            guard viewModel.isDraft else { return }
            composeBar.defaultPlaceholder = "Post as \(identity.name)"
        }
        viewModel.onPublished = { [weak self] entry in self?.becomePublished(entry) }
        viewModel.onPublishFailed = { [weak self] text in self?.restoreUnpublished(text) }
        viewModel.onCommentFailed = { [weak self] text, refused in self?.restoreUnsent(text, refused: refused) }
        viewModel.onCommentPosted = { [weak self] id in self?.stream.arrivingCommentID = id }
        viewModel.onVoiceCommentFailed = { [weak self] refused in
            // The row keeps it, with its retry; the author's refusal is said.
            guard refused else { return }
            let notice = Self.commentFailureNotice(refused: true)
            self?.presentNotice(notice.title, notice.message)
        }
        viewModel.onReviewFailed = { [weak self] approve in
            let notice = Self.reviewFailureNotice(approve: approve)
            self?.presentNotice(notice.title, notice.message)
        }
        viewerSwitch.configureProfileSwitcher()
        // The empty page's floor is its block's own height, which the text
        // size changes — see `refitEmptyPage`.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: PostDetailViewController, _: UITraitCollection) in
            controller.streams.forEach {
                $0.refitEmptyPage()
                // …and Popular's cut is the threads that fit at that size (#2298).
                $0.refitCut()
            }
        }
        // …and the keyboard takes the room the page is fitted to.
        keyboardWatch.observeKeyboardForEmptyPage()
        render(.loading)
        viewModel.viewDidLoad()
        if showsPopular { viewModel.loadPopularIfNeeded() }
    }

    @objc func handleStreamTap() {
        view.endEditing(true)
    }

    /// A tap on a row's BODY while the keyboard is up retires the keyboard —
    /// the stream tap's rule — and does not arm a reply.
    ///
    /// The stream tap alone could not deliver that: the row's own reply tap
    /// is nearer the touch, recognizes first and PREVENTS the stream's
    /// (`cancelsTouchesInView = false` governs touch delivery to views, not
    /// recognition between recognizers), so a tap on any comment
    /// re-armed a reply and kept the keyboard up — most of the stream was
    /// "outside the keyboard" and did nothing of the kind. Arbitrating here,
    /// in the row's own action, keeps every other recognizer's answer as it
    /// was: the ♥ and the avatar are controls and still act, the fold seams
    /// still expand, a drag still scrolls (and dismisses interactively).
    func retireKeyboardOr(_ work: () -> Void) {
        if composeBar.isEditingDraft {
            view.endEditing(true)
        } else {
            work()
        }
    }

    // MARK: - Setup

    private func configureViews() {
        streams.forEach { $0.configure() }
        configureComposeBar()
        // Scroll view fills above the compose bar. The default bottom stops
        // at the bar's top at rest, and at its input row's top while the
        // keyboard lifts the row above the bar (the bar itself never moves):
        // the higher of the two, pulled down to the bar by a low-priority
        // reach. The engaged context swaps all three for a full-bleed bottom
        // so the stream glides BEHIND the footer.
        let streamView = pager
        let reach = streamView.bottomAnchor.constraint(equalTo: composeBar.topAnchor)
        reach.priority = .defaultLow
        scrollBottomDefault = [
            streamView.bottomAnchor.constraint(lessThanOrEqualTo: composeBar.topAnchor),
            streamView.bottomAnchor.constraint(lessThanOrEqualTo: composeBar.inputRowTopAnchor),
            reach,
        ]
        streamView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(streamView)
        NSLayoutConstraint.activate([
            streamView.topAnchor.constraint(equalTo: view.topAnchor),
            streamView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            streamView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ] + scrollBottomDefault)

        statusView.isHidden = true
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            // Above the keyboard, so a raised composer never sits on it.
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
    }

    // MARK: - Draft (the "+" menu's Text Post)

    /// Where a published draft is handed on: the Text Post page, which keeps
    /// this panel and changes its own bars from "writing" to "the post".
    var onPostPublished: ((FeedEntry) -> Void)?

    /// How many comments the stream holds — what the sort control waits on
    /// (`CommentSortPolicy`). Reported on every change.
    private(set) var commentCount = 0
    var onCommentCountChange: ((Int) -> Void)?

    /// The stream counted its comments: reported on a change.
    func noteCommentCount(_ count: Int) {
        recentDidCount(count)
        guard count != commentCount else { return }
        commentCount = count
        onCommentCountChange?(count)
        // Popular's "See all n comments" says the post's count (#2298).
        if cutsStreamsToRoom, isViewLoaded { popular.syncLinkRows() }
    }

    /// The composer's text, for a host that keeps drafts of it.
    var composerText: String {
        get { composeBar.draftText }
        set { composeBar.draftText = newValue }
    }

    var onComposerTextChange: ((String) -> Void)? {
        didSet { composeBar.onTextChange = onComposerTextChange }
    }

    /// Who will see the post, in the boost's slot — see
    /// `CommentsInputBar.visibilityMenu`. Nil puts the boost back.
    func setVisibilityMenu(_ menu: UIMenu?) {
        composeBar.visibilityMenu = menu
    }

    /// A draft whose first message is on its way — already sent, past recall.
    var isPublishing: Bool { viewModel.isDraft && composeBar.isSending }

    /// Hides the draft's stream — its invitation — while the host shows an
    /// attachment in its place (#2216: a showcase's card, above the
    /// composer). A published post's page always shows its stream.
    func setDraftStreamHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        streamSurface.isHidden = hidden && viewModel.isDraft
    }

    #if DEBUG
    func debugSend(_ text: String) { composeBar.debugSend(text) }
    /// The boost button's spend, as its tap hands it over.
    func debugBoost(_ spend: WalletStakeSpend) { composeBar.onBoost?(spend) }
    #endif

    /// The composer of a post that does not exist yet.
    ///
    /// - The footer band wears the TEXT page's veil from the start. It is set
    ///   from a loaded post's format (`configure`), and a draft has no post:
    ///   left at zero it would be a bare blur that snaps to the text veil the
    ///   moment the post is published.
    /// - It says what it does: it publishes.
    private func configureDraft() {
        // Not a post's comments yet: no voice comment. A draft that publishes
        // voices declares a voice post's (`TextPostComposerViewController`).
        composeBar.configuration.voice = .none
        composerBackdrop.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        composeBar.defaultPlaceholder = "Write your post…"
        composeBar.sendAccessibilityLabel = "Publish post"
    }

    /// The draft is a post now: the composer goes back to being a post's —
    /// "Comment as …", a send that comments, the boost in the slot the
    /// visibility held (a published post's audience is settled), and the
    /// post's sound in the rail slot.
    private func becomePublished(_ entry: FeedEntry) {
        // The draft's voice post goes with the draft. Its recorder stays the
        // page's (`TextPostComposerViewController`): the page just published
        // takes no voice comment — opened again, it does (#2309).
        composeBar.configuration.voice = .none
        composeBar.defaultPlaceholder = nil
        composeBar.sendAccessibilityLabel = nil
        composeBar.visibilityMenu = nil
        rail.applyPublishedFace()
        boost.refreshBoostTotal()
        onPostPublished?(entry)
        // A post now: it has its two tabs and opens on Popular, the caption
        // first (#2287, no threshold) — the draft had none. Whatever the
        // writer scrolled while drafting, the post opens on Popular.
        hasChosenOpeningTab = false
        popularBecameAvailable()
    }

    /// The post did not go out. The composer cleared itself when the text was
    /// sent, so the text is put back — ahead of anything typed since.
    private func restoreUnpublished(_ text: String) {
        let typedSince = composeBar.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        composeBar.draftText = typedSince.isEmpty ? text : text + "\n" + composeBar.draftText
        presentNotice(
            "Couldn't Publish",
            viewModel.publishFailureReason
                ?? "Your post wasn't published. Your text is still here, so you can try again."
        )
    }

    /// A comment that didn't go: its text comes back, and the notice says
    /// whether the author limits comments (#397) or it simply failed.
    private func restoreUnsent(_ text: String, refused: Bool) {
        let typedSince = composeBar.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        composeBar.draftText = typedSince.isEmpty ? text : text + "\n" + composeBar.draftText
        let notice = Self.commentFailureNotice(refused: refused)
        presentNotice(notice.title, notice.message)
    }

    /// The text page family's notices are alerts — see the conversation's.
    func presentNotice(_ title: String, _ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func configureComposeBar() {
        rail.applyOpeningFace()
        // The Liquid Glass composer (Private Messages' recipe): a floating
        // capsule field, no opaque bar, no separator — the glass carries
        // its own boundary against whatever is behind it.
        composeBar.onSend = { [weak self] text in
            guard let self else { return }
            // A sent reply must be visible where it lands: expand its
            // thread before the reload-driven re-render.
            if let target = self.replyTarget {
                self.expandedReplyParents.insert(target.parentID)
            }
            self.viewModel.submitComment(text, parentID: self.replyTarget?.parentID)
            self.clearReplyState()
        }
        // The reply state's natural exit: keyboard retired over an empty
        // field — later compositions start top-level again.
        composeBar.onIdleDismiss = { [weak self] in self?.clearReplyState() }
        boost.install()
        // The engaged footer band (hidden outside the engagement): below
        // the bar, above the stream.
        composerBackdrop.isHidden = true
        composerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBackdrop)
        view.addSubview(composeBar)
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        // Sits at the safe-area bottom for good; only its input row rides the
        // keyboard (`riseWithKeyboard`). Stored: the engaged context replaces
        // it (`setEngagedInsets`) — there the composer must occupy the NATIVE
        // FOOTER'S band, which the safe area deliberately still contains.
        let bottom = composeBar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.sm
        )
        composeBottomDefault = bottom
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            // The column's inset from the screen's edge, so the column stands
            // on the media layout's bubbles.
            composeBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -SnapActionColumn.trailingInset
            ),
            bottom,
            composerBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // The band starts ABOVE the composer by the lead, so its ramp
            // is finished — full material — by the time it reaches the
            // capsule's top edge. Anchored to the composer, so it rides the
            // keyboard with it — to its INPUT ROW, not the bar's top: the
            // stake bubble above the row floats in the ramp, and the band
            // keeps the height it had before the bubble moved up there.
            composerBackdrop.topAnchor.constraint(
                equalTo: composeBar.inputRowTopAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
        ])
        composeBar.riseWithKeyboard(of: view.keyboardLayoutGuide)
    }

    /// The feed's paging: the composer's page swipe, the pull past the
    /// streams' ends and the page's VoiceOver actions
    /// (`PostDetailFeedPaging`). Built on first use; building it does
    /// nothing else.
    private(set) lazy var feedPaging = PostDetailFeedPaging(host: self)
    func setEngagedPageSwipeHandler(
        _ handler: @escaping (CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void,
        pagesBack: @escaping () -> Bool
    ) {
        feedPaging.setEngagedPageSwipeHandler(handler, pagesBack: pagesBack)
    }
    var pagesBackFromStreamTop: (() -> Bool)? { feedPaging.pagesBackFromStreamTop }
    var postPull: PostPull? { feedPaging.postPull }
    func setPostPull(_ pull: PostPull) { feedPaging.setPostPull(pull) }
    func postPullTarget(_ direction: PostPullDirection) -> PostPullTarget? { feedPaging.postPullTarget(direction) }

    /// The STREAM's shrink for the engagement, 0 (engaged) → 1 (dismissed).
    ///
    /// It scales the list and nothing else. The composer and the footer's
    /// blur band are siblings of the list, not children, so they hold their
    /// size and position at the screen's edge while the content pulls away —
    /// which is the whole point: a band that scales stops being chrome and
    /// starts being part of the moving layer.
    func setStreamTransitionProgress(_ progress: CGFloat) {
        let t = min(max(0, progress), 1)
        let scale = 1 + (SnapCommentsLayout.streamEntranceScale - 1) * t
        streamSurface.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// The composer's entrance state for the engaged footer handoff:
    /// offstage = invisible. ALPHA ONLY: the column's bubbles stand on the
    /// media layout's like and repost bubbles (`SnapActionColumn`), and a
    /// slide would move them — the two layouts crossfade in place.
    /// Set offstage BEFORE the spring; animate to onstage INSIDE it.
    func setComposerEntranceState(offstage: Bool) {
        composeBar.alpha = offstage ? 0 : 1
        // The footer band rides the same seam — this already runs inside the
        // master spring both ways, and `effect` is the one animatable path
        // for a material. Window-guarded (headless CI never pays for a real
        // blur) and gated on the engaged context (outside it there is no
        // band).
        if offstage {
            composerBackdrop.effect = nil
        } else if view.window != nil, !composerBackdrop.isHidden, composerBackdrop.effect == nil {
            composerBackdrop.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    /// Extra bottom room so resting content clears the composer: the bar's
    /// resting top above the footer line (its rest gap and its height, the
    /// lifted column and the stake on it included), plus the breath a resting
    /// row keeps above it — the column's two bubbles sit at the trailing
    /// edge, where a resting row's ♥ would be.
    ///
    /// ⚠️ LESS THE SECTION'S OWN BOTTOM INSET (#1923). The last row already
    /// ends `Spacing.lg` above the content's end; counted on top of the
    /// breath, the comments rested ~24 pt higher over the composer than a
    /// conversation's messages over theirs (the owner, 2026-10-30). The two
    /// streams now keep the same `Spacing.sm` there.
    var engagedFooterClearance: CGFloat {
        composerRestingGap + restingComposerHeight(for: .large) + Self.composerTopBreath
            - streamSectionVerticalInsets
    }

    /// The resting composer's height: its column as it stands — the slot
    /// alone once a media page folds its column (#1923).
    func restingComposerHeight(for category: UIContentSizeCategory) -> CGFloat {
        CommentsInputBar.restingHeight(for: category, showsStake: composeBar.showsStake)
    }

    /// Between the resting composer's top and the last row resting above it:
    /// a conversation's (`ConversationThreadViewController.syncBottomClearance`).
    private static let composerTopBreath: CGFloat = Spacing.sm

    /// The composer's resting gap above the footer line: its input row
    /// `glassGap` above the toolbar's glass — the bar lifts its own column
    /// (`SnapActionColumn`).
    var composerRestingGap: CGFloat { SnapActionColumn.inputRestingGap + composerLift }

    /// (#1716, #1722): the composer rises with the page's bottom block — one
    /// breath over the bar — so the action column keeps its place.
    private var composerLift: CGFloat = SnapActionColumn.bottomBreath

    func setComposerLift(_ lift: CGFloat) {
        guard lift != composerLift else { return }
        // A rest line already drawn moves by the difference.
        composeBottomEngaged.first?.constant -= lift - composerLift
        composerLift = lift
    }

    func setEngagedInsets(top: CGFloat, bottomInset: CGFloat) {
        // The strip inset is the ONLY top authority in the engaged context:
        // the full-cell scroll view would otherwise also inherit the safe
        // area's automatic adjustment and double-inset the resting position.
        // TOTAL immersion: the stream spans the full height and glides
        // BEHIND the footer too — the scroll's bottom swaps from the
        // compose bar's top to the view's bottom, with a bottom inset so
        // resting content still clears the footer band. The frost keeps
        // the bar legible over the moving rows.
        NSLayoutConstraint.deactivate(scrollBottomDefault)
        if scrollBottomEngaged == nil {
            scrollBottomEngaged = streamSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        scrollBottomEngaged?.isActive = true
        // Recorded so the empty page can be sized against the SETTLED
        // geometry on frame 0 — the stream is still growing into these
        // numbers while the transition runs.
        engagedStreamInsets = (
            top: max(0, top),
            bottom: max(0, bottomInset) + engagedFooterClearance
        )
        streams.forEach { $0.applyEngagedInsets(top: max(0, top), bottom: max(0, bottomInset) + engagedFooterClearance) }
        updateComposerBackdropVisibility()
        // Z-ORDER, load-bearing: the scroll view is added AFTER the compose
        // bar at build time (harmless while it ended at the bar's top), so
        // at full height it would sit ABOVE the footer and swallow every
        // touch in the band — taps, the ✕, the swipe pan (found via hit
        // logging: bar frame contained the point, a CommentRowView won).
        // The footer must cap the stack in the engaged context.
        view.bringSubviewToFront(composerBackdrop)
        view.bringSubviewToFront(composeBar)

        // The composer OCCUPIES THE NATIVE FOOTER'S BAND: the feed keeps
        // its toolbar structurally present for the whole engagement (the
        // safe area must never move — that's the zero-churn contract), so
        // the resting position anchors to the WINDOW's home-indicator
        // inset (`bottomInset`, toolbar-independent) instead of the safe
        // area. The keyboard never moves the BAR: its input row rides the
        // guide on its own (`riseWithKeyboard`), measured from the screen's
        // edge too.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        composeBottomDefault?.isActive = false
        NSLayoutConstraint.deactivate(composeBottomEngaged)
        // The rest line: the input row `glassGap` above the toolbar's glass. The bar
        // lifts its own column off that line, onto the media layout's like
        // and repost bubbles (`SnapActionColumn`).
        let rest = composeBar.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -(max(0, bottomInset) + composerRestingGap)
        )
        composeBottomEngaged = [rest]
        rest.isActive = true
    }

    /// Whether a stream shorter than its room starts from the bottom (#1799,
    /// the default since #1923) — Recent's, as the panel's resting contract
    /// says (`CommentStreamResting`, #2287). ⚠️ A TEST SEAM, NEVER A HOST'S:
    /// no host sets it — each gives the room, never the rest. Settable for
    /// tests, before the stream is engaged.
    var anchorsShortStream = true

    /// How far the keyboard lifts the composer's input row above where it
    /// rests: the room a short stream gives up, so it rises with the row
    /// rather than going behind the keys (#1799). The keyboard never touches
    /// the stream's insets (`currentEmptyPageFit`).
    var keyboardLift: CGFloat {
        guard composerTracksKeyboard, let covered = keyboardHeightFromBottom,
              let engaged = engagedStreamInsets else { return 0 }
        let category = traitCollection.preferredContentSizeCategory
        let restingBottomInset = engaged.bottom - engagedFooterClearance
        let restingTop = view.bounds.height - restingBottomInset - composerRestingGap
            - restingComposerHeight(for: category)
        let risenTop = view.bounds.height - covered - Spacing.sm - CommentsInputBar.restingInputRowHeight(for: category)
        return max(0, restingTop - risenTop)
    }

    /// Whether the composer's input row is allowed to be lifted by the
    /// KEYBOARD (`CommentsInputBar.tracksKeyboard`).
    ///
    /// ⚠️ THE CEILING IS ANCHORED TO THE SCREEN, and a page that is only
    /// partly on it hangs below. `keyboardLayoutGuide` is a window-space guide:
    /// with no keyboard up its top sits at the bottom of the SCREEN, and the
    /// constraint is required — so a panel whose own view extends past the
    /// bottom (a page scrolling in, whose cell is still half below) has its
    /// composer pinned to the screen's edge instead of travelling with the
    /// page. Two composers are then visible at once: the page's, moving, and
    /// this one, stuck. Reported exactly that way.
    ///
    /// Only the page a viewer can actually type on needs it, so it is granted
    /// rather than assumed — off while a panel is standing in for a page that
    /// is arriving, on when that page becomes the one being read.
    func setComposerTracksKeyboard(_ tracks: Bool) {
        composerTracksKeyboard = tracks
        composeBar.tracksKeyboard = tracks
    }

    var composerTracksKeyboard = true

    // MARK: - Render

    private func render(_ phase: PostDetailViewModel.Phase) {
        switch phase {
        case .loading:
            statusView.isHidden = true
            // The skeleton stream IS the loading state (the messages
            // doctrine) — no spinner, no hidden surface.
            streamSurface.isHidden = false
            for stream in streams where !stream.hasAppliedStream { stream.applyStream(animated: false) }
        case .content(let model):
            statusView.isHidden = true
            streamSurface.isHidden = false
            setPostActionsShown(true)
            configure(model)
        case .failed(let message):
            streamSurface.isHidden = true
            // ⚠️ A WAY OUT (#797): "Pull to retry" was promised over a
            // collection this hides, so it could not be done.
            statusView.configure(
                symbolName: "exclamationmark.triangle", title: message,
                actionTitle: "Try Again", actionHandler: { [weak self] in
                    self?.statusView.setActionBusy(true)
                    self?.viewModel.refresh()
                }
            )
            // Beneath the composer: its taps are never the empty state's.
            if composerBackdrop.superview === view { view.insertSubview(statusView, belowSubview: composerBackdrop) }
            statusView.isHidden = false
        case .unavailable(let message):
            // A draft, a deleted post or one withheld from this viewer
            // (#447): the same block, without Try Again — and nothing left
            // to act on it with (#1404).
            streamSurface.isHidden = true
            setPostActionsShown(false)
            statusView.configure(symbolName: "eye.slash", title: message)
            if composerBackdrop.superview === view { view.insertSubview(statusView, belowSubview: composerBackdrop) }
            statusView.isHidden = false
        }
    }

    /// Whether the post's actions are on screen: the composer — its field,
    /// the stake (like) bubble, the boost and the rail slot — and the engaged
    /// footer's band under it.
    ///
    /// A post the server shows the viewer no more (#447) has none (#1404):
    /// a like or a comment would only be refused. The way back stays, and it
    /// is the host's — the back button, the sheet's grabber. IN PLACE: a post
    /// that turns unavailable while shown (its revalidation answers
    /// not-found) loses them where it stands, as one that opens unavailable
    /// never shows them.
    private(set) var showsPostActions = true

    private func setPostActionsShown(_ shown: Bool) {
        guard shown != showsPostActions else { return }
        showsPostActions = shown
        if !shown {
            // What was being typed has nowhere to go: the keyboard leaves
            // with the field, and the reply it was aimed at with it.
            composeBar.endEditing(true)
            clearReplyState()
            // A boost still in its undo window keeps its toast, Undo live; if
            // it is sent, the server refuses the stake and the outbox's
            // answer puts it back (`settleCommittedStake`, #676).
        }
        composeBar.isHidden = !shown
        updateComposerBackdropVisibility()
        // Back, the band's material comes back with it: the entrance builds
        // one only for a band that is showing, and this one was not.
        if shown { setComposerEntranceState(offstage: composeBar.alpha == 0) }
        // The host draws post actions of its own — the snap page's like,
        // boost and sound column (#1409): it is told, once per screen.
        if !shown, let postID = viewModel.postID { onPostUnavailable?(postID) }
    }

    /// The footer band shows in the engaged context (`setEngagedInsets`)
    /// under a composer that is shown — never under one an unavailable post
    /// took away (#1404).
    private func updateComposerBackdropVisibility() {
        composerBackdrop.isHidden = !showsPostActions || engagedStreamInsets == nil
    }

    private func configure(_ model: PostDetailDisplayModel) {
        // Retained for the caption row: the stream's first item renders from
        // this, and a re-render must not have to go back to the view model.
        let hadCaption = latestPost?.hasCaption == true
        latestPost = model
        setTakesComments(model.takesComments)
        // The footer band's veil, from the post's own format — the model
        // already knows, so this needs no signal from the host.
        composerBackdrop.setVeilOpacity(
            SnapCommentsLayout.frostVeilOpacity(hasMedia: model.hasMedia)
        )
        for stream in streams where model.hasCaption != hadCaption || stream.hasAppliedStream {
            // The apply that FIRST introduces the caption row lands without
            // animation, even though the stream has been applied before.
            //
            // Diffable animates an insertion by fading the cell in, and the
            // caption cell is a `UIVisualEffectView` — alpha on an effect
            // view is unsupported and renders the material as a flat opaque
            // grey for the fade's duration. That is the "bubble loads dark
            // then flashes light" report: measured #8F8F8F → #A7A7A7 →
            // #AEAEAE → #FCFCFC, an alpha ramp, while the glass logged
            // `.light` at every step. The appearance was never wrong — the
            // row was being faded in.
            //
            // There is nothing to animate FROM in any case: the caption is
            // the post's own content arriving, exactly like the cold load
            // the first apply already lands unanimated.
            stream.applyStream(animated: Self.animatesStreamApply(
                hasAppliedStream: stream.hasAppliedStream,
                introducesCaption: model.hasCaption && !hadCaption
            ))
        }
    }

    /// A showcase's page takes no comments (#2216): the composer keeps its
    /// column — the like, Share — and loses its input row; a reply aimed
    /// before it was known has nowhere to go.
    private func setTakesComments(_ takes: Bool) {
        guard takes != takesComments else { return }
        takesComments = takes
        composeBar.takesComments = takes
        guard !takes else { return }
        clearReplyState()
        // ⚠️ THE TABS GO TOO, EVEN THOUGH "ONCE THERE, IT STAYS". The opener's
        // comment count can bring Popular in before the page knows it is a
        // showcase — a page opened from a cached entry seeds the count first
        // (seen on the simulator: Popular / Recent over a showcase). A
        // showcase has no comments to rank, so the panel goes back to Recent
        // alone and tells its host, which reads `showsPopular` again.
        if showsPopular {
            showsPopular = false
            if isViewLoaded {
                pager.setActivePage(Self.recentPage, animated: false)
                pager.isPagingEnabled = false
                if lastSettledStream !== stream { visibleStreamDidChange() }
            }
            onCommentCountChange?(commentCount)
        }
    }

    private func renderEngagement(_ state: PostDetailViewModel.EngagementState) {
        // The caption row carries the like count in its closing line, and it
        // is a LIVE one: the viewer can like the post from the toolbar with
        // that row on screen.
        // ⚠️ ONLY ONCE THE POST HAS LANDED. The state starts at zero for every
        // screen, and a zero before the fetch is not a count — it is the
        // absence of one, and the row would assert "nobody liked this" over
        // the number the opener actually handed it.
        setCaptionLikeCount(latestPost == nil ? nil : state.likeCount)
    }

    /// The count the caption row's closing line shows: the live one once the
    /// post has landed, the opener's until then, `nil` when nobody has said.
    private var liveLikeCount: Int64?
    var captionLikeCount: Int64? { liveLikeCount ?? seededCardMetrics?.reactions }

    /// Re-renders the caption row when — and only when — its number changed.
    ///
    /// Reconfigure, never reload: the row is a `UIVisualEffectView`, and a
    /// diffable reload fades a cell in, which renders a glass material as flat
    /// opaque grey for the fade's duration (the "bubble loads dark then flashes
    /// light" report).
    private func setCaptionLikeCount(_ count: Int64?) {
        let before = captionLikeCount
        liveLikeCount = count
        pushComposerLikeCount()
        guard captionLikeCount != before else { return }
        streams.forEach { $0.reconfigureCaption() }
    }

    /// Renders the caption row NOW, from what the opener already knows.
    ///
    /// The row is the stream's first item and it existed only once the POST had
    /// loaded — a network round trip after the panel mounts — so a text page
    /// opened from the feed showed its comments before its own caption, and the
    /// caption dropped in afterwards. The feed already holds the caption and
    /// the timestamp, so it hands them over at mount and the real post replaces
    /// the row later with the same text, moving nothing.
    /// The AUTHOR and the counts come from the opener, because only it has
    /// them: the row is an avatar beside a bubble whatever the post is made of,
    /// and a `FeedEntry` carries a like count and neither a view nor a comment
    /// count — so a hydrated model knows less than the grid that opened this.
    /// The post's comment count as the opener knows it (#1773): the
    /// skeleton stream draws no more bones than that, and none for zero.
    func seedCommentCount(_ count: Int64?) {
        let waiting = streams.filter { !$0.commentsLoaded }
        guard !waiting.isEmpty, count != knownCommentCount else { return }
        knownCommentCount = count
        // The opener's count decides the opening tab when it reaches the
        // threshold: Popular from the first frame (#2007).
        if !hasChosenOpeningTab, let count, CommentSortPolicy.isAvailable(commentCount: Int(count)) {
            popularBecameAvailable()
        }
        guard isViewLoaded else { return }
        waiting.forEach { $0.applyStream(animated: false) }
    }

    #if DEBUG
    /// Whether the empty page's row says the first page is taking longer.
    var debugShowsTakingLonger: Bool { stream.debugShowsTakingLonger }
    /// The skeleton rows in the stream now — what a test reads.
    var debugSkeletonRowCount: Int { stream.debugSkeletonRowCount }
    #endif

    func seedCaption(
        _ text: String,
        timestamp: String,
        authorName: String = "",
        monogram: String = "",
        avatarURL: URL? = nil,
        metrics: PostCardMetrics? = nil,
        voice: PostVoice? = nil,
        embed: PostEmbed? = nil
    ) {
        // A voice alone is a caption too (#2207), and so is a card (#2216).
        guard !text.isEmpty || voice != nil || embed != nil, latestPost == nil else { return }
        seededCaption = (text, timestamp)
        seededVoice = voice
        seededEmbed = embed
        setTakesComments(embed == nil)
        seededAuthor = (authorName, monogram, avatarURL)
        seededCardMetrics = metrics
        loadViewIfNeeded()
        pushComposerLikeCount()
        streams.forEach { $0.applyStream(animated: false) }
    }

    /// The post this panel is about — nil on a draft.
    var postID: PostID? { viewModel.postID }

    // MARK: The way back (#1929)

    /// The way back came or went — for a host whose page draws the sound
    /// bubble above this composer (the snap feed's column).
    var onScrollAwayChange: ((Bool) -> Void)?
    /// Whether the way back shows now.
    var showsScrollAwayReturn: Bool { stream.showsScrollAwayReturn }
    /// Whether it points down: Recent's start is its newest (#2007).
    var scrollAwayReturnsDown: Bool { stream.returnsDown }
    /// The composer's rail slot: its face, the way back, Share and the
    /// sound's gestures (`PostDetailRailSlot`), the only writer of
    /// `composeBar.railFace`. Built on first use; building it does nothing
    /// else.
    private(set) lazy var rail = PostDetailRailSlot(host: self)
    /// The composer's slot as the way back stands (`PostDetailRailSlot`).
    func applyRailWayBack() { rail.applyRailWayBack() }
    func setRailShare(_ action: (() -> Void)?, holdArms: Bool = false) { rail.setRailShare(action, holdArms: holdArms) }
    func setRailSoundFace(_ face: SnapSoundFace?, keepsSlot: Bool = true) {
        rail.setRailSoundFace(face, keepsSlot: keepsSlot)
    }
    func setRailSoundSpinning(_ spinning: Bool) { rail.setRailSoundSpinning(spinning) }
    func setRailSoundActions(tap: (() -> Void)?, hold: (() -> Void)?) { rail.setRailSoundActions(tap: tap, hold: hold) }

    /// The post turned out unavailable to the viewer (#447) — said once, as
    /// this panel takes its own actions away (#1404). For a host that draws
    /// post actions outside the panel: the snap page (#1409).
    var onPostUnavailable: ((PostID) -> Void)?

    /// The composer alone — the avatar, the field and the own bubble, no
    /// column: no stake, no slot (the comments sheet, #2087,
    /// the owner 2026-11-03). The row takes the column's width, as it does on
    /// a page with no slot (#1999). The sheet's contract (#2308).
    func setComposerBare() {
        var sheet = ComposerConfiguration.commentsSheet
        // The sheet's voice is the page's: a voice comment where the source
        // carries one (#2309).
        sheet.voice = commentsVoice
        composeBar.configuration = sheet
        composeBar.hostsActionColumn = true
        rail.clearForBareComposer()
    }

    /// The snap feed's page draws the action column above this panel (#695):
    /// the composer only reserves its room.
    ///
    /// ⚠️ A MEDIA PAGE FOLDS ITS COLUMN (`foldsIntoSlot`). With the comments
    /// up, its like folds into the sound bubble (#1872): only the slot is
    /// left, on the input row's line. Reserving the stake there kept ~110 pt of nothing over the
    /// field, and the stream, anchored to the bottom, rested that far above
    /// the composer (#1923, the owner's film). The composer keeps the slot
    /// alone, as a conversation's does; a text page's column never folds
    /// and keeps its whole room.
    func setActionColumnHostedByPage(_ hosted: Bool, foldsIntoSlot: Bool = false) {
        if composeBar.hostsActionColumn != !hosted {
            composeBar.hostsActionColumn = !hosted
            applyRailWayBack()
        }
        let standsStake = !(hosted && foldsIntoSlot)
        guard composeBar.showsStake != standsStake else { return }
        let clearance = engagedFooterClearance
        composeBar.showsStake = standsStake
        // Insets set before this keep the old clearance: set them again.
        guard let engaged = engagedStreamInsets else { return }
        setEngagedInsets(top: engaged.top, bottomInset: engaged.bottom - clearance)
    }

    /// The page's overlay offset as the side list opens (#1730): the
    /// composer moves down with the caption and the action column, so its
    /// input row stays on the sound cover's line.
    func setOverlayOffset(_ offset: CGFloat) {
        composeBar.setOverlayOffset(offset)
    }

    /// The composer's offset now. Tests.
    var debugComposerOverlayOffset: CGFloat { composeBar.transform.ty }
    /// The way back (#1929), for tests.
    var debugRailFace: CommentsInputBar.RailFace { composeBar.railFace }
    var debugRailSoundHold: HoldToArmPresenter? { rail.railSoundHold }
    /// What VoiceOver offers on the slot while the way back shows (#1999).
    var debugRailCustomActions: [UIAccessibilityCustomAction]? {
        composeBar.railHoldTarget.accessibilityCustomActions
    }
    /// A tap on the slot, through its own action.
    func debugTapRail() { composeBar.onRailAction?() }
    /// The stream moved to `offset` — by the reader, or not.
    func debugScroll(to offset: CGFloat, userScroll: Bool) {
        stream.debugScroll(to: offset, userScroll: userScroll)
    }
    var debugStreamOffset: CGFloat { stream.collectionView.contentOffset.y }
    var debugStreamTopOffset: CGFloat { -stream.collectionView.adjustedContentInset.top }

    /// The stake bubble's like badge reads the caption row's count — one
    /// number on one panel.
    private func pushComposerLikeCount() {
        composeBar.setLikeCount(captionLikeCount)
    }

    /// The first page's bones on the kit's timing (#1770). Injectable so a
    /// test steps it.
    var skeletonClock: LoadingClock = .system

    /// The engaged context's own insets, kept so the settled geometry can be
    /// computed before the transition has produced it. Nil until engaged.
    var engagedStreamInsets: (top: CGFloat, bottom: CGFloat)?

    /// The keyboard's height for the empty page, and its three observers
    /// (`PostDetailKeyboardWatch`). Built on first use; building it does
    /// nothing else.
    private(set) lazy var keyboardWatch = PostDetailKeyboardWatch(host: self)
    /// How much of the screen's bottom the keyboard covers while it is up
    /// (`PostDetailKeyboardWatch.keyboardHeightFromBottom`).
    var keyboardHeightFromBottom: CGFloat? { keyboardWatch.keyboardHeightFromBottom }

    /// The empty stream's section insets, mirroring the layout
    /// (`collectionView`): no top inset — the stream leads with its caption
    /// row, even while a draft has none yet — and `Spacing.lg` at the bottom.
    var streamSectionVerticalInsets: CGFloat { Spacing.lg }

    // MARK: - The day under the header (#757)

    /// The day of the last chip gone under the stream's top edge — what the
    /// host's bar shows left of the points — or nil before one has, or with
    /// no days at all (Popular, a skeleton, an empty page).
    var onDayUnderHeaderChange: ((Date?) -> Void)?
    private(set) var dayUnderHeader: Date?

    func syncDayUnderHeader() {
        var day = groupsByDay ? stream.lastDayGoneUnderTheTop() : nil
        #if DEBUG
        if let debugDayUnderTheTop { day = debugDayUnderTheTop() }
        #endif
        guard day != dayUnderHeader else { return }
        dayUnderHeader = day
        onDayUnderHeaderChange?(day)
    }

    /// Re-reads the day under the top. Tests, and the host after a layout.
    func debugSyncDayUnderHeader() { syncDayUnderHeader() }

    #if DEBUG
    /// Stands in for the stream's geometry, for tests about the HOST's bar
    /// rather than the scroll: the day this panel reports at its next sync.
    var debugDayUnderTheTop: (() -> Date?)?
    /// Hears every `scrollToDay`, for tests of what a tap reaches.
    var debugOnScrollToDay: ((Date) -> Void)?
    /// Whether the composer's input row may rise with the keyboard — the bar's
    /// own answer, not this controller's record of it (#969).
    var debugComposerTracksKeyboard: Bool { composeBar.tracksKeyboard }
    #endif

    /// Row tapped: the composer arms its reply state — placeholder names
    /// the tapped author, the payload binds to the THREAD parent, and the
    /// keyboard rises into the field.
    func enterReplyState(for model: CommentDisplayModel) {
        replyTarget = (parentID: model.parentID ?? model.id, name: model.authorName)
        composeBar.setReplyPlaceholder(name: model.authorName)
        composeBar.focusComposer()
    }

    func clearReplyState() {
        replyTarget = nil
        composeBar.setReplyPlaceholder(name: nil)
    }

    // MARK: - Voice comments (#2309)

    /// The voice the comments' field records: a comment's — a minute, in
    /// seconds — on a post's comments whose source uploads voices; none on a
    /// draft (its host declares a voice post's) or from a source that
    /// carries no voice.
    var commentsVoice: ComposerConfiguration.Voice {
        viewModel.acceptsVoiceComments ? .comment : .none
    }

    /// The comments' voice: the field's recorder and its takes, sent as
    /// voice comments (`PostDetailVoiceComments`). Built on first use;
    /// building it does nothing else.
    private(set) lazy var voiceComments = PostDetailVoiceComments(host: self)
    /// The field's recorder (`PostDetailVoiceComments.voiceComposer`).
    var voiceComposer: VoiceComposer? { voiceComments.voiceComposer }
    func sendVoiceComment(_ take: CommentVoiceTake) { voiceComments.sendVoiceComment(take) }
    func retryVoiceComment(_ commentID: String) { voiceComments.retryVoiceComment(commentID) }

    /// A comment's Copy says so (#803). Internal for tests.
    func confirmCopied() {
        Feedback.success("Copied", symbol: "doc.on.doc.fill", from: self)
    }

    func presentCommentShare(_ model: CommentDisplayModel) {
        let sheet = UIActivityViewController(
            // A voice alone shares as "🎙 12″" (#2309), never "Ava: ".
            activityItems: ["\(model.authorName): \(model.oneLineText)"],
            applicationActivities: nil
        )
        present(sheet, animated: true)
    }

    private func renderComposing(_ composing: Bool) {
        composeBar.isSending = composing
        onComposingChange?(composing)
    }

    /// Whether a send is in flight — for a host that must not let go of the
    /// screen meanwhile: the Text Post page, while its post is on its way.
    var onComposingChange: ((Bool) -> Void)?
}
