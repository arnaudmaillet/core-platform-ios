import AuthInterface
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import ProfileInterface
import UIKit

/// The stream's diffable identity space. Content is looked up at cell-
/// configure time (`streamModels`); identity is what animates.
/// `.day` exists only with the text page's chrome on (`threadChrome`): the
/// threads grouped under a pinned pill per day.
enum StreamSection: Hashable {
    case main
    case day(Date)
}

/// What the layout's section provider needs to know about the snapshot it is
/// laying out — which sections carry a day pill, and which is last. Read by a
/// provider that must not reach back through the controller (see the layout's
/// own note), written before every apply.
private final class StreamSectionPolicy: @unchecked Sendable {
    private(set) var isGrouped = false
    private(set) var pinnedSections: Set<Int> = []
    private(set) var lastSection = 0

    /// Returns whether the grouping changed — a layout built for one shape
    /// must be invalidated before the other is applied.
    @discardableResult
    func update(_ sections: [StreamSection]) -> Bool {
        let wasGrouped = isGrouped
        pinnedSections = Set(sections.indices.filter {
            if case .day = sections[$0] { return true }
            return false
        })
        isGrouped = !pinnedSections.isEmpty
        lastSection = max(0, sections.count - 1)
        return wasGrouped != isGrouped
    }
}
enum StreamItem: Hashable {
    /// The post's caption, as the list's first row — a message bubble in
    /// the thread rather than a fixed header above it.
    case caption
    case emptyState
    case skeletonPlaceholder(Int)
    case comment(String)
    case seam(CommentThreadToggleRow.Kind, parentID: String)
    /// The room at a tier's end where the "More" button stands (#2042):
    /// the last row read never goes under it.
    case tierEnd
}

@MainActor
final class CommentStream: NSObject {
    /// The panel the stream belongs to: its post, its composer and the
    /// geometry they share. The panel owns the stream.
    unowned let host: PostDetailViewController

    /// Which of the panel's streams this is (#2007).
    enum Kind {
        /// The server's ranking: most liked first, the viewer's own leading.
        /// It rests at its top and pages downward.
        case popular
        /// A conversation: oldest above, the newest just above the composer.
        /// It rests at its end, and older pages land above it without moving
        /// what is on screen.
        case recent
    }

    let kind: Kind

    init(host: PostDetailViewController, kind: Kind = .recent) {
        self.host = host
        self.kind = kind
        super.init()
    }

    // The panel's state, read as the stream's own.
    private var viewModel: PostDetailViewModel { host.viewModel }
    private var imagePipeline: ImagePipeline { host.imagePipeline }
    private var threadChrome: Bool { host.threadChrome }
    private var groupsByDay: Bool { host.groupsByDay }
    private var view: UIView { host.view }
    private var traitCollection: UITraitCollection { host.traitCollection }
    private var composeBar: CommentsInputBar { host.composeBar }
    private var latestPost: PostDetailDisplayModel? { host.latestPost }
    private var engagedStreamInsets: (top: CGFloat, bottom: CGFloat)? { host.engagedStreamInsets }
    private var keyboardHeightFromBottom: CGFloat? { host.keyboardHeightFromBottom }
    /// A short Recent starts from the bottom (#1799); a short Popular rests
    /// at its top, as a ranking does (#2007).
    private var anchorsShortStream: Bool { kind == .recent && host.anchorsShortStream }
    private typealias EmptyPageCopy = PostDetailViewController.EmptyPageCopy
    private var keyboardLift: CGFloat { host.keyboardLift }
    private var composerTracksKeyboard: Bool { host.composerTracksKeyboard }
    private var captionLikeCount: Int64? { host.captionLikeCount }
    private var seededCaption: (text: String, timestamp: String)? { host.seededCaption }
    private var seededAuthor: (name: String, monogram: String, avatarURL: URL?)? { host.seededAuthor }
    private var knownCommentCount: Int64? { host.knownCommentCount }
    private var expandedReplyParents: Set<String> {
        get { host.expandedReplyParents }
        set { host.expandedReplyParents = newValue }
    }
    private var streamSectionVerticalInsets: CGFloat { host.streamSectionVerticalInsets }
    private var engagedFooterClearance: CGFloat { host.engagedFooterClearance }
    private var composerRestingGap: CGFloat { host.composerRestingGap }
    private func restingComposerHeight(for category: UIContentSizeCategory) -> CGFloat {
        host.restingComposerHeight(for: category)
    }
    private var isViewLoaded: Bool { host.isViewLoaded }
    private var onPullDismissDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)? {
        host.onPullDismissDrive
    }

    /// Builds the list: its bounce, its taps, its menus and its rows.
    func configure() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        pageView.addSubview(collectionView)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        pageView.addSubview(moreButton)
        let edge = kind == .popular
            ? moreButton.bottomAnchor.constraint(equalTo: pageView.bottomAnchor)
            : moreButton.topAnchor.constraint(equalTo: pageView.topAnchor)
        moreButtonEdge = edge
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: pageView.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            moreButton.centerXAnchor.constraint(equalTo: pageView.centerXAnchor),
            edge,
        ])
        observeContentSize()
        // The comment list BOUNCES, and the bounce is the transition's
        // driver: past the top, `contentOffset` IS the pull, rubber-banded
        // by UIKit's own curve, so the fade and the overscroll cannot drift
        // out of step — they are the same number. (Locking the offset and
        // reading the pan instead was the previous shape; it worked, but the
        // content sat frozen while the layer moved, which read as two
        // surfaces rather than one.)
        //
        // It keeps NO refresh control, though: that competed for the same
        // gesture outright.
        collectionView.alwaysBounceVertical = true
        collectionView.bounces = true
        // ⚠️ CLEAR, THE ONE TITLED EXCEPTION (#1591): this list is the snap
        // feed's EMBEDDED comment stream (`commentsContentVC`), where a soft
        // blur would draw a band over the panel.
        collectionView.prefersClearTopEdge()
        collectionView.keyboardDismissMode = .interactive
        // A bare tap on the stream retires the keyboard (the drag path
        // above already does; taps should match). Non-cancelling, so row
        // interactions and the cell-side arbitration see every touch
        // unchanged — and a no-op when nothing is editing. A row's body
        // wins its own taps, so it applies the same rule itself
        // (`retireKeyboardOr`).
        let keyboardDismissTap = UITapGestureRecognizer(target: host, action: #selector(PostDetailViewController.handleStreamTap))
        keyboardDismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(keyboardDismissTap)
        // With bouncing back on, the overshoot itself is the signal — the
        // scroll delegate reports it continuously, during the drag AND
        // through the spring-back, which is what makes the cancel free.
        collectionView.delegate = self
        if threadChrome {
            // One long press for the whole stream, lifting the pressed row.
            // Nothing is installed without the chrome, so the rows' own menus
            // arbitrate exactly as before.
            rowContextMenu.install(on: collectionView)
            rowContextMenu.menuProvider = { [weak self] indexPath in self?.rowMenu(at: indexPath) }
        }
        configureStreamDataSource()
    }

    /// A tap at `location` in the stream's coordinates, through the
    /// recogniser's own decision, for tests.
    func debugTapStream(at location: CGPoint) {
        guard emptyRoomTap.isEnabled, emptyRoomContains(location) else { return }
        tapEmptyRoom()
    }

    /// The engaged context's insets (`PostDetailViewController.setEngagedInsets`):
    /// `top` under the strip, `bottom` clearing the footer.
    func applyEngagedInsets(top: CGFloat, bottom: CGFloat) {
        // The strip inset is the ONLY top authority in the engaged context:
        // the full-cell scroll view would otherwise also inherit the safe
        // area's automatic adjustment and double-inset the resting position.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = top
        collectionView.verticalScrollIndicatorInsets.top = top
        collectionView.contentOffset = CGPoint(x: 0, y: -top)
        // A clean minimal stream: no indicator (engaged context only).
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInset.bottom = bottom
        restingBottomInset = bottom
        // On top of the engaged top, never instead of it (#1799): the slack
        // is measured against the settled room, and the stream lands at
        // `-(top + slack)`.
        bottomAnchorSlack = 0
        syncBottomAnchor()
        if holdsRest { pinToTail() }
        // The "More" button stands where the stream's rows end: just above
        // the composer under Popular, just below the top bar over Recent.
        moreButtonEdge?.constant = kind == .popular
            ? -(bottom + streamSectionVerticalInsets) - (Self.tierEndHeight - Self.moreButtonHeight) / 2
            : top + (Self.tierEndHeight - Self.moreButtonHeight) / 2
    }

    // MARK: - The "More" button (#2042)

    /// The stream's page in the panel's pager: the list, and the "More"
    /// button over it.
    let pageView = UIView()

    /// The button's constraint to its edge, placed with the engaged insets.
    private var moreButtonEdge: NSLayoutConstraint?
    /// The button's height, as its configuration draws it at the default size.
    static let moreButtonHeight: CGFloat = 36

    /// "More comments": a small Liquid Glass capsule at the end of a tier,
    /// with its chevron pointing where the next tier comes in.
    private lazy var moreButton: UIButton = {
        var config = UIButton.Configuration.glass()
        config.attributedTitle = AttributedString("More comments", attributes: AttributeContainer([
            .font: UIFont.scaledFont(forTextStyle: .footnote, weight: .semibold),
        ]))
        config.image = UIImage(
            systemName: kind == .popular ? "chevron.down" : "chevron.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        )
        config.imagePlacement = .trailing
        config.imagePadding = Spacing.xs
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "comments.moreTier"
        button.addAction(UIAction { [weak self] _ in self?.revealNextTier(animated: true) }, for: .primaryActionTriggered)
        button.alpha = 0
        button.isHidden = true
        return button
    }()

    /// Whether the "More" button shows: reading in tiers, at the end of the
    /// tier — Popular's bottom, Recent's top — with a next tier to show, and
    /// the keyboard down.
    var showsMoreButton: Bool {
        guard hasNextTier, !composeBar.isKeyboardOpen else { return false }
        // Once the tier's end room is mostly in sight, not at the edge to the
        // point: a tier a few points taller than its room still shows it.
        let reach = Self.tierEndHeight / 2
        let insets = collectionView.adjustedContentInset
        return kind == .popular
            ? collectionView.contentOffset.y >= tailOffset - reach
            : collectionView.contentOffset.y <= -insets.top + reach
    }

    /// The button as the stream stands, faded in or out.
    func syncMoreButton() {
        let shows = showsMoreButton
        guard shows == moreButton.isHidden else { return }
        if shows { moreButton.isHidden = false }
        let button = moreButton
        let apply = { button.alpha = shows ? 1 : 0 }
        guard collectionView.window != nil else {
            apply()
            button.isHidden = !shows
            return
        }
        // Weak: the stream reads its host, which may be gone by the fade's end.
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply) { [weak self] _ in
            guard let self, showsMoreButton == shows else { return }
            button.isHidden = !shows
        }
    }

    #if DEBUG
    /// The button, for tests.
    var debugMoreButton: UIButton { moreButton }
    /// The room a tier is measured against, its section insets included.
    var debugTierRoom: CGFloat { availableStreamHeight }
    #endif

    /// The caption row's closing line changed: re-rendered in place.
    ///
    /// Reconfigure, never reload: the row is a `UIVisualEffectView`, and a
    /// diffable reload fades a cell in, which renders a glass material as flat
    /// opaque grey for the fade's duration (the "bubble loads dark then flashes
    /// light" report).
    func reconfigureCaption() {
        guard streamDataSource != nil else { return }
        var snapshot = streamDataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.caption) else { return }
        snapshot.reconfigureItems([.caption])
        streamDataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Whether the way back shows now (#1929).
    var showsScrollAwayReturn: Bool { scrollAway.showsReturn }

    /// The engaged bottom inset with the composer at rest (`applyEngagedInsets`).
    private var restingBottomInset: CGFloat?

    /// ⚠️ RECENT RIDES THE KEYBOARD, as a conversation does (the owner,
    /// 2026-11-01): the composer's input row rising by `rise` lifts the
    /// conversation with it — its newest row stays just above the field, and
    /// a reader further up keeps the rows they were reading on screen. Popular
    /// stays where it is, under the keyboard, as before. Each stream holds its
    /// own inset, so the tabs change with the keyboard up and both stay right.
    ///
    /// Called from the panel's layout pass (`viewDidLayoutSubviews`), which a
    /// keyboard runs inside its own animation: the inset and the offset land
    /// in that block and ride the keyboard's curve. The offset is read before
    /// the inset is written, which clamps it (`ConversationThreadViewController.syncBottomClearance`),
    /// and a finger dragging the keyboard down owns the offset itself.
    func syncKeyboardRise(_ rise: CGFloat) {
        guard kind == .recent, let resting = restingBottomInset else { return }
        let inset = resting + max(0, rise)
        let delta = inset - collectionView.contentInset.bottom
        guard abs(delta) > 0.5 else { return }
        let offsetBefore = collectionView.contentOffset.y
        collectionView.contentInset.bottom = inset
        guard hasAppliedStream, !collectionView.isTracking else { return }
        if holdsRest {
            pinToTail()
        } else {
            let insets = collectionView.adjustedContentInset
            collectionView.contentOffset.y = min(max(offsetBefore + delta, -insets.top), tailOffset)
        }
    }

    /// The stream moved to `offset` — by the reader, or not. Tests.
    func debugScroll(to offset: CGFloat, userScroll: Bool) {
        collectionView.contentOffset.y = offset
        if userScroll { holdsRest = isAtRest }
        syncScrollAway(userScroll: userScroll)
    }

    #if DEBUG
    /// Whether the last apply animated. Tests.
    private(set) var debugLastApplyAnimated = false
    /// The comments the stream holds. Tests.
    var debugCommentCount: Int { latestComments.count }
    #endif

    #if DEBUG
    /// Whether the empty page's row says the first page is taking longer.
    var debugShowsTakingLonger: Bool {
        streamItems().contains(.emptyState) && emptyPageCopy == PostDetailViewController.commentsTakingLongerPageCopy
    }
    /// The skeleton rows in the stream now — what a test reads.
    var debugSkeletonRowCount: Int {
        streamItems().filter { if case .skeletonPlaceholder = $0 { true } else { false } }.count
    }
    #endif

    private let streamPolicy = StreamSectionPolicy()
    private lazy var rowContextMenu = ThreadRowContextMenu()

    /// The stream surface: a compositional-list collection view driven by
    /// a diffable data source — thread folds and sort re-ranks land as
    /// NATIVE animated snapshot applies (insertions, deletions, moves),
    /// never manual view surgery. Still a UIScrollView underneath, so the
    /// engaged inset/keyboard machinery operates on it unchanged.
    private(set) lazy var collectionView: UICollectionView = {
        // Captured by VALUE: the layout closure outlives nothing here, but a
        // section provider that reaches back through `self` is a retain cycle
        // waiting for someone to forget the `weak`.
        let policy = streamPolicy
        let layout = UICollectionViewCompositionalLayout { index, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            // Symmetric margins: the stream owns the full width. (The
            // trailing inset used to carry an exclusion for the shortcut
            // rail's column; the engagement fades the rail now, so there is
            // no column to leave clear.)
            // NO TOP INSET: the stream leads with the caption row, and the
            // caption row already carries one.
            //
            // It is the CARD's `captionTopInset`, reproduced deliberately so
            // that a reveal opening the gallery row into this page finds its
            // caption at the same offset inside the row at both ends of the
            // flight. A section inset above it is therefore a SECOND top
            // padding on the same edge — 32pt of air over a caption the card
            // sets 16pt down — and the page opened looking loose against the
            // row it grew from.
            //
            // Dropping it moves the row up bodily, caption and all, so the
            // reveal's registration is untouched: the anchor is the row's own
            // frame and it travels with it.
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: Spacing.lg,
                bottom: Spacing.lg,
                trailing: Spacing.lg
            )
            // GROUPED BY DAY (text pages only). The single section's
            // insets are split across the pieces so the stream's outline does
            // not move: the caption section keeps the top, the LAST section
            // keeps the bottom, and nothing in between adds any.
            if policy.isGrouped {
                if index > 0 { section.contentInsets.top = 0 }
                if index != policy.lastSection { section.contentInsets.bottom = 0 }
                if policy.pinnedSections.contains(index) {
                    let pill = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)
                        ),
                        elementKind: DayPillHeaderView.elementKind,
                        alignment: .top
                    )
                    // ⚠️ NOT STICKY (#757, the owner's call 2026-10-10): the
                    // chip scrolls with its day; the host's bar says which
                    // day is under the header (`onDayUnderHeaderChange`).
                    pill.pinToVisibleBounds = false
                    pill.zIndex = 2
                    section.boundarySupplementaryItems = [pill]
                }
            }
            return section
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.allowsSelection = false
        return view
    }()
    private var streamDataSource: UICollectionViewDiffableDataSource<StreamSection, StreamItem>!
    /// Snapshot bookkeeping: the first apply lands without animation (a
    /// cold load has nothing to animate FROM); everything after — folds,
    /// sorts, submissions — animates natively.
    private(set) var hasAppliedStream = false
    /// True for the one apply that replaces the skeleton rows with the
    /// loaded comments: those cells fade in, staggered, instead of popping.
    /// A post whose comments were cached never shows bones and never sets
    /// this, so its rows are there at once (charter P7, P10).
    private var revealsLoadedRows = false
    /// Views staged for the reveal, played once the apply is over — see
    /// `playStagedReveal`.
    private var stagedReveals: [UIView] = []
    private(set) var commentsLoaded = false
    /// The first page of comments failed with nothing to show (#798): the
    /// empty row says so, with a Try Again, instead of "No comments yet".
    private var commentsFailed = false
    /// What the failed row says: the view model's words, "You're offline"
    /// when that is why (#794).
    private var commentsFailureText = PostDetailViewModel.commentsFailureMessage
    private var streamModels: [String: CommentDisplayModel] = [:]

    /// The threaded stream as last loaded — kept so expansion re-renders
    /// without a refetch.
    private var latestComments: [CommentDisplayModel] = []

    /// Re-fits a shown empty page to the current geometry and text size.
    ///
    /// Two things move its fit after it was decided: the room (a sheet's
    /// detent, above) and the block's own height, which is the page's floor
    /// and grows with the text size. `applyStream` reconfigures the page
    /// only if the fit really changed, so a call that finds nothing to do
    /// costs one measurement.
    func refitEmptyPage() {
        guard hasAppliedStream, renderedEmptyPageFit != nil else { return }
        applyStream(animated: false)
    }

    /// The width the stream's self-sizing rows were last measured against.
    private var lastMeasuredStreamWidth: CGFloat = 0

    /// Re-measures every row when the stream's width changes.
    ///
    /// Self-sizing rows are measured once, at whatever width the list has
    /// when they are configured — and on the feed's RESTING engagement that
    /// is a width the container has not finished resolving, because the
    /// comments are installed into a cell from `willDisplay` while the page
    /// is still arriving. The caption row got measured narrow, kept the
    /// height that came out of it, and its label — tail-truncating by
    /// default — ended a three-line caption in an ellipsis on line one. The
    /// same run measured 58pt one launch and 33.67pt the next, which is the
    /// tell: nothing was wrong with the text, only with WHEN it was asked.
    ///
    /// Nothing re-asked, because a compositional list does not re-measure
    /// self-sizing content on a bounds change by itself. This does, once per
    /// genuine width change — so rotation and the iPad's size classes are
    /// covered by the same line.
    func remeasureStreamOnWidthChange() {
        let width = collectionView.bounds.width
        guard width > 0, abs(width - lastMeasuredStreamWidth) > 0.5 else { return }
        let isFirst = lastMeasuredStreamWidth == 0
        lastMeasuredStreamWidth = width
        // The very first width is not a CHANGE — the rows have not been
        // measured against anything yet, and re-applying inside the first
        // layout pass would fight the apply that is putting them there.
        guard !isFirst, hasAppliedStream else { return }
        remeasureStream()
    }

    /// A tap in the EMPTY ROOM above a short stream closes the comments
    /// (#1926, the owner): the room the bottom anchor leaves between the top
    /// bar and the caption (`bottomAnchorSlack`) is the media's, as the ✕
    /// says. Wired by media pages only, as the pull-down is; nil turns it
    /// off. A stream that fills its room has no such room: nothing changes.
    ///
    /// ⚠️ FILTERED AT `shouldReceive`, so the tap never sees a touch on a row:
    /// it cannot compete with the rows' own taps, the pull-down or a scroll.
    func setEmptyRoomTapHandler(_ handler: (() -> Void)?) {
        onEmptyRoomTap = handler
        if handler != nil, emptyRoomTap.view == nil {
            collectionView.addGestureRecognizer(emptyRoomTap)
        }
        emptyRoomTap.isEnabled = handler != nil
    }
    private var onEmptyRoomTap: (() -> Void)?

    private lazy var emptyRoomTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(emptyRoomTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = emptyRoomFilter
        return tap
    }()

    private lazy var emptyRoomFilter = TouchFilter { [weak self] location in
        self?.emptyRoomContains(location) ?? false
    }

    /// Whether `location`, in the stream's own coordinates, is in the empty
    /// room: above the content's first row, while the anchor leaves room
    /// there.
    func emptyRoomContains(_ location: CGPoint) -> Bool {
        bottomAnchorSlack > 0.5 && location.y < 0
    }

    @objc private func emptyRoomTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, emptyRoomContains(tap.location(in: collectionView)) else { return }
        tapEmptyRoom()
    }

    /// With the keyboard up, the first tap puts the keyboard away — the
    /// writer is only leaving the field — and the next one closes.
    private func tapEmptyRoom() {
        if keyboardHeightFromBottom != nil {
            view.endEditing(true)
            return
        }
        onEmptyRoomTap?()
    }

    /// Set once a released pull has committed, so the spring-back that
    /// follows cannot drive the transition backwards over the dismissal
    /// already in flight.
    private var isCommittingPullDismiss = false
    /// Whether the gesture in flight is allowed to drive the dismissal —
    /// armed only when the drag PHYSICALLY BEGAN at the top.
    ///
    /// It outlives the drag on purpose: a released pull that fell short
    /// springs home, and the transition has to ride that bounce back to
    /// rest before disarming, or it would freeze mid-fade.
    private var isPullDismissArmed = false

    /// Freezes the comment stream for the length of a gesture that owns the
    /// screen — a dismissal swipe.
    ///
    /// The stream is a `UIScrollView`, and a full-surface pan lives on the
    /// feed's view ABOVE it, so the two recognise simultaneously: a swipe with
    /// any vertical component scrolled the comments while the page slid away
    /// under the finger. Freezing here rather than vetoing in the pan's
    /// delegate because the stream's own pan may already have begun — a
    /// begin-time veto cannot stop a recognizer that is already running, but a
    /// disabled scroll view stops dead.
    ///
    /// Restores the value that was there rather than assuming `true`: the
    /// stream is also frozen by the resting engagement's settle lock, and a
    /// gesture that ended inside that window must not thaw it early.
    /// Whether the stream rests at its very top — the one place a downward
    /// drag has nothing left to scroll, which is where a RESTING page's
    /// vertical slide-to-dismiss may claim the touch instead (the sheet
    /// idiom; see `SnapFeedViewController.zoomVerticalDismissalPermitted`).
    /// Same top test the pull-dismiss arming uses.
    var streamIsAtTop: Bool {
        collectionView.contentOffset.y <= -collectionView.contentInset.top + 0.5
    }

    /// The mirror, for the swipe UP past a finished source (#628): nothing
    /// left to scroll below, so an upward drag has no stream to move. A stream
    /// shorter than its viewport is at both ends at once.
    var streamIsAtBottom: Bool {
        let insets = collectionView.adjustedContentInset
        let lowest = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        return collectionView.contentOffset.y >= lowest - 0.5
    }

    func setStreamScrollEnabled(_ enabled: Bool) {
        if enabled { streamLock.thaw(collectionView) } else { streamLock.freeze(collectionView) }
    }

    /// Held for the length of a dismissal gesture. See `ScrollLock` for why
    /// this restores rather than enables.
    private var streamLock = ScrollLock()

    /// The room above a short stream, worn in the top inset on top of the
    /// engaged top (`syncBottomAnchor`).
    private(set) var bottomAnchorSlack: CGFloat = 0

    /// A short stream STARTS FROM THE BOTTOM (#1799, the default since
    /// #1923): the caption and its comments are one block, the post its
    /// first message, resting just above the composer — the room above them
    /// (`StreamBottomAnchor`) worn in the top inset, ON TOP of the engaged
    /// top. No order changes: Recent, Popular, replies under
    /// their parent and downward paging are as before; expanding a thread's
    /// replies in a short stream grows the block upward.
    ///
    /// Measured against the SETTLED room (`availableStreamHeight`): the stream
    /// is still growing into the engaged geometry while the transition runs.
    /// A stream as tall as its room wears no slack and is exactly as before.
    ///
    /// The stream rests at its top, `-(top + slack)`: a stream resting there
    /// keeps resting there as the slack changes (and so the pull-down
    /// dismissal, armed at `-contentInset.top`, stays armed); one the reader
    /// scrolled is left where it is.
    func syncBottomAnchor(animated: Bool = false) {
        guard anchorsShortStream, let engaged = engagedStreamInsets else { return }
        let room = availableStreamHeight - keyboardLift
        guard room > 0 else { return }
        // An invitation with no caption (a text post's draft) is full height
        // and centred, never anchored — as an empty conversation's. Decided
        // before the layout below: forced on a page still being fitted, it
        // froze the invitation's row at a stale height.
        let standsAlone = emptyPageStandsAlone
        guard !standsAlone || bottomAnchorSlack != 0 else { return }
        if !standsAlone { collectionView.layoutIfNeeded() }
        let slack = standsAlone
            ? 0
            : StreamBottomAnchor.slack(viewport: room, contentHeight: collectionView.contentSize.height)
        guard abs(slack - bottomAnchorSlack) > 0.5 || abs(collectionView.contentInset.top - (engaged.top + slack)) > 0.5
        else { return }
        let wasResting = collectionView.contentOffset.y <= -collectionView.contentInset.top + 0.5
        bottomAnchorSlack = slack
        let apply = {
            self.collectionView.contentInset.top = engaged.top + slack
            self.collectionView.verticalScrollIndicatorInsets.top = engaged.top + slack
            if wasResting { self.collectionView.contentOffset.y = -(engaged.top + slack) }
        }
        if animated, view.window != nil {
            UIView.animate(
                withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                animations: apply
            )
        } else {
            apply()
        }
    }

    /// Scrolled away from the post's text, the sound offers the way back to
    /// the top: a tap goes there, a hold arms the sound sheet.
    private var scrollAway = ScrollAwayPolicy()

    /// Feeds the way-back policy: the distance from the stream's start —
    /// Popular's top, Recent's newest (#2007).
    private func syncScrollAway(userScroll: Bool) {
        let insets = collectionView.adjustedContentInset
        let distance = abs(collectionView.contentOffset.y - restingOffset)
        let viewport = collectionView.bounds.height - insets.top - insets.bottom
        let before = scrollAway.showsReturn
        scrollAway.update(distance: distance, viewport: viewport, isUserScroll: userScroll)
        // Only the tab on screen speaks for the way back (#2007); the other
        // is read when it comes in (`visibleStreamDidChange`).
        guard scrollAway.showsReturn != before, host.stream === self else { return }
        host.onScrollAwayChange?(scrollAway.showsReturn)
        host.applyRailWayBack()
    }

    /// Back to the stream's start (#1929, #2007) — Popular's top, the post's
    /// text; Recent's newest — animated: UIKit's animated offset runs in a
    /// fixed time whatever the distance, so a long way back never drags.
    func scrollToStart(animated: Bool) {
        holdsRest = true
        isScrollingProgrammatically = animated && abs(collectionView.contentOffset.y - restingOffset) > 0.5
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: restingOffset), animated: animated)
    }

    /// Whether the way back points down: Recent's start is its end (#2007).
    var returnsDown: Bool { kind == .recent }

    // MARK: - Where the stream rests (#2007)

    /// The offset that shows the stream's last row.
    private var tailOffset: CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
    }

    /// Where the stream rests: Popular at its top, Recent at its end.
    private var restingOffset: CGFloat {
        kind == .recent ? tailOffset : -collectionView.adjustedContentInset.top
    }

    /// Whether the stream is at its resting end now.
    private var isAtRest: Bool { abs(collectionView.contentOffset.y - restingOffset) <= 0.5 }

    /// Whether the stream stays at its resting end as its content changes:
    /// until the reader scrolls away from it, and again once they come back
    /// (`scrollViewDidScroll`). Popular's top keeps itself (UIKit holds the
    /// offset); Recent's end is held here (`keepRestingEnd`).
    private var holdsRest = true

    /// Set while the paging rows are being laid out at an offset the stream
    /// is about to leave: they must not ask for a page then.
    private var suppressesPaging = false

    /// Recent back at its end, exactly — estimated heights refine as the rows
    /// at the tail realise, so each pass lays out at the offset it just set,
    /// until the content stops moving (bounded), as a conversation's tail pin
    /// does (`ConversationThreadViewController.pinToTail`).
    private func pinToTail(animated: Bool = false) {
        guard kind == .recent, collectionView.bounds.height > 0 else { return }
        suppressesPaging = true
        defer { suppressesPaging = false }
        guard !animated else {
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: tailOffset), animated: true)
            return
        }
        for _ in 0..<4 {
            collectionView.layoutIfNeeded()
            let height = collectionView.contentSize.height
            collectionView.contentOffset.y = tailOffset
            collectionView.layoutIfNeeded()
            if abs(collectionView.contentSize.height - height) < 0.5 { break }
        }
    }

    /// Recent kept at its end through a layout pass — the stream growing into
    /// its room, a width change — unless a finger or a scroll animation has
    /// the list.
    /// ⚠️ THE SLACK FOLLOWS THE ROWS' OWN SIZING TOO: rows that size
    /// themselves as the stream first comes on screen grow its content with
    /// no apply and no layout of the panel's — a slack measured before them
    /// left Recent resting past its top, under the bar (and its "More" out of
    /// reach).
    private var contentSizeObservation: NSKeyValueObservation?
    private var followsContentSizeSoon = false

    private func observeContentSize() {
        contentSizeObservation = collectionView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followContentSizeSoon() }
        }
    }

    /// Next turn, outside the layout pass that changed it; once per turn.
    private func followContentSizeSoon() {
        guard !followsContentSizeSoon else { return }
        followsContentSizeSoon = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            followsContentSizeSoon = false
            syncBottomAnchor()
            keepRestingEnd()
            syncMoreButton()
        }
    }

    func keepRestingEnd() {
        guard kind == .recent, holdsRest, !isAtRest, !collectionView.isTracking,
              !collectionView.isDecelerating, !isScrollingProgrammatically else { return }
        pinToTail()
    }

    /// An animated scroll of the stream's own is on its way.
    private var isScrollingProgrammatically = false

    /// A scroll of the stream's own — a day's chip: where it ends decides
    /// whether the stream still holds its resting end.
    private func scrollProgrammatically(to y: CGFloat, animated: Bool) {
        isScrollingProgrammatically = animated
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: animated)
        if !animated { holdsRest = isAtRest }
    }

    /// The topmost row on screen and its distance from the viewport's top —
    /// what an apply holds in place (`hold`).
    private func visibleAnchor() -> (item: StreamItem, offset: CGFloat)? {
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let item = streamDataSource.itemIdentifier(for: indexPath),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.maxY > collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            else { continue }
            switch item {
            case .comment, .seam, .caption: return (item, frame.minY - collectionView.contentOffset.y)
            default: continue
            }
        }
        return nil
    }

    /// Puts the anchored row back where it was on screen, once the rows above
    /// it exist: older pages land above Recent, the viewer's own above
    /// Popular, and nothing on screen moves.
    ///
    /// ⚠️ UNTIL IT STAYS, as `pinToTail`: the rows realised at the new offset
    /// refine their estimated heights, and the first pass lands a few points
    /// off (measured: 6.7 pt on an older page).
    private func hold(_ anchor: (item: StreamItem, offset: CGFloat)) {
        suppressesPaging = true
        defer { suppressesPaging = false }
        for _ in 0..<4 {
            collectionView.layoutIfNeeded()
            guard let indexPath = streamDataSource.indexPath(for: anchor.item),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            let target = frame.minY - anchor.offset
            guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
            collectionView.contentOffset.y = target
        }
    }

    /// Where the caption bubble is drawn, in `space` — the reveal transition's
    /// matched anchor (`RevealGeometry.anchorFrame`).
    ///
    /// Read from the LAYOUT rather than from a realized cell: the anchor is
    /// wanted at the instant the page is first laid out, which is before the
    /// collection view has necessarily dequeued anything, and a nil answer
    /// there silently degrades the matched reveal to the plain one. Layout
    /// attributes exist as soon as the snapshot does.
    ///
    /// Nil when the stream has no caption row at all — a post whose caption is
    /// empty, which has no anchor and wants the plain reveal.
    /// ⚠️ READ ONCE, AT STAGING — never per event.
    ///
    /// `convert(_:to:)` composes ancestor transforms, and the reveal drives the
    /// page by one. Today every caller asks before the first pose is applied,
    /// so the answer is in untransformed space and correct. A future per-event
    /// re-read would inherit the presenter's own depth scale as well, which has
    /// already been measured once on this transition: a 343x145 row came back
    /// as 325.85x137.75 mid-drag.
    func revealCaptionAnchor(in space: UICoordinateSpace) -> CGRect? {
        guard let indexPath = streamDataSource?.indexPath(for: .caption),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else { return nil }
        return collectionView.convert(attributes.frame, to: space)
    }

    private lazy var commentsGate: ListSkeletonGate = {
        let gate = ListSkeletonGate(clock: host.skeletonClock)
        gate.onChange = { [weak self] in
            guard let self, !commentsLoaded, hasAppliedStream else { return }
            applyStream(animated: false)
        }
        return gate
    }()

    func renderComments(_ state: PostDetailViewModel.CommentsState) {
        // ⚠️ THE FIRST PAGE WAITS OUT ITS BONES' MINIMUM (#1770) — the
        // newest answer, once; the staged reveal plays when it lands.
        if !commentsLoaded, state != .loading {
            return commentsGate.landed { [weak self] in self?.renderCommentsNow(state) }
        }
        renderCommentsNow(state)
    }

    private func renderCommentsNow(_ state: PostDetailViewModel.CommentsState) {
        let models: [CommentDisplayModel]
        switch state {
        case .loaded(let loaded):
            models = loaded
        case .failed(let message):
            // Whatever a landing was scrolling for is gone with the stream.
            _ = takePendingLanding()
            // The empty row, in its failed words (`emptyPageCopy`): the stream
            // has nothing, and the reason is a failure, not an empty post.
            commentsFailed = true
            commentsFailureText = message
            latestComments = []
            streamModels = [:]
            commentsLoaded = true
            applyStream(animated: hasAppliedStream)
            return
        case .loading:
            // Ordinarily ignored: a refresh over loaded comments keeps them on
            // screen. A Try Again from the failed row is the exception — the
            // row goes back to bones, so the answer arrives the way a first
            // load's does (`revealLoadedComments`).
            guard commentsFailed else { return }
            _ = takePendingLanding()
            commentsFailed = false
            commentsLoaded = false
            applyStream(animated: hasAppliedStream)
            return
        }
        // A posted comment whose landing was still scrolling: THIS render
        // applies the stream, its own included (#921). Taken only by a render
        // that applies — an ignored `.loading` must not drop it.
        let interruptedLanding = takePendingLanding()
        commentsFailed = false
        latestComments = models
        // Taken HERE, whichever way this render goes: a posted comment's
        // arrival belongs to the render that brings it, never a later one.
        let arriving = arrivingCommentID ?? interruptedLanding?.id
        arrivingCommentID = nil
        let previous = streamModels
        streamModels = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A row keeps its identity (the comment id) when it is approved, its
        // review starts or its likes move (#637), so the diff alone would
        // leave it drawn as before.
        let reviewChanged = models.compactMap { model -> StreamItem? in
            guard let old = previous[model.id],
                  old.isHeld != model.isHeld || old.canReview != model.canReview
                    || old.likeCount != model.likeCount || old.isLiked != model.isLiked else { return nil }
            return .comment(model.id)
        } + (interruptedLanding?.reconfiguring ?? [])
        // Bones were on screen and real rows are about to take their place.
        let replacesBones = !commentsLoaded && hasAppliedStream && !models.isEmpty
        commentsLoaded = true
        if kind == .recent { host.noteCommentCount(models.count) }
        if replacesBones {
            revealLoadedComments()
            return
        }
        // The first apply lands cold (nothing to animate FROM); reloads,
        // sort re-ranks, and submissions animate as native diffs — moves,
        // insertions, deletions, all UIKit's own.
        guard let arriving, hasAppliedStream else {
            applyStream(animated: hasAppliedStream, reconfiguring: reviewChanged)
            return
        }
        landPostedComment(arriving, reconfiguring: reviewChanged)
    }

    /// A posted comment whose stream is waiting for the list to get there.
    private var pendingLanding: (id: String, reconfiguring: [StreamItem], target: CGPoint)?
    /// Bumped by every landing, so a scroll that was overtaken lands nothing.
    private var landingGeneration = 0

    /// The viewer's comment lands WHERE THEY CAN SEE IT (#921): the list first
    /// goes to its slot, then the comment arrives there with its effect — it
    /// is never inserted off screen. A slot already on screen skips the scroll.
    private func landPostedComment(_ id: String, reconfiguring: [StreamItem]) {
        // Recent's newest is the viewer's now: the stream goes to its end and
        // stays there (#2007), as a conversation does.
        if kind == .recent { holdsRest = true }
        guard let target = landingOffset(for: id) else {
            insertPostedComment(id, reconfiguring: reconfiguring)
            return
        }
        #if DEBUG
        debugLandingEvents.append("scroll:\(id)")
        #endif
        landingGeneration += 1
        let generation = landingGeneration
        pendingLanding = (id, reconfiguring, target)
        // ⚠️ A REAL SCROLL, not a bounds animation. Animating the offset in a
        // `UIView.animate` block lays out only the destination's cells: the
        // rows in between never exist, and the list showed EMPTY frames on the
        // way up (filmed 2026-10-11). The scroll's end is the landing's cue
        // (`scrollViewDidEndScrollingAnimation`); a timeout covers the scroll
        // a drag interrupts, which ends without saying so.
        guard !MotionPreference.reducesMotion else {
            collectionView.setContentOffset(target, animated: false)
            finishLanding(generation)
            return
        }
        isScrollingProgrammatically = true
        collectionView.setContentOffset(target, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + PostDetailViewController.landingScrollTimeout) { [weak self] in
            self?.finishLanding(generation)
        }
    }

    /// The list got there (or gave up): the comment lands. Only the landing
    /// still in flight, and only once.
    private func finishLanding(_ generation: Int) {
        guard landingGeneration == generation, let pending = takePendingLanding() else { return }
        // ⚠️ THE TIMEOUT IS NOT PROOF OF ARRIVAL: a starved main thread can
        // still be mid-scroll when it fires, and inserting then would land the
        // comment off screen — the one thing this exists to prevent. Short of
        // the slot, the list gets there now; a finger on it keeps the say.
        if abs(collectionView.contentOffset.y - pending.target.y) > 0.5, !collectionView.isDragging {
            collectionView.setContentOffset(pending.target, animated: false)
        }
        collectionView.layoutIfNeeded()
        insertPostedComment(pending.id, reconfiguring: pending.reconfiguring)
    }

    /// Ends a landing in flight and hands it back — nil when none was. Its
    /// scroll's completion then lands nothing.
    private func takePendingLanding() -> (id: String, reconfiguring: [StreamItem], target: CGPoint)? {
        guard let pending = pendingLanding else { return nil }
        pendingLanding = nil
        landingGeneration += 1
        return pending
    }

    private func insertPostedComment(_ id: String, reconfiguring: [StreamItem]) {
        #if DEBUG
        debugLandingEvents.append("insert:\(id)")
        #endif
        applyStream(animated: true, reconfiguring: reconfiguring)
        playArrival(ofPostedComment: id)
    }

    /// Where the list must go for `id`'s slot to be on screen, or nil when it
    /// already is (or cannot be told). The slot is the bottom of the row the
    /// comment will follow in the NEW stream — a row already on screen's data,
    /// so its place is known before the comment exists. The list goes so the
    /// slot sits a third of the way down what is visible.
    private func landingOffset(for id: String) -> CGPoint? {
        let items = streamSections().flatMap(\.items)
        guard let index = items.firstIndex(of: .comment(id)) else { return nil }
        let slotY: CGFloat
        if index == 0 {
            slotY = 0
        } else {
            guard let path = streamDataSource.indexPath(for: items[index - 1]),
                  let anchor = collectionView.layoutAttributesForItem(at: path) else { return nil }
            slotY = anchor.frame.maxY
        }
        let insets = collectionView.adjustedContentInset
        let offset = collectionView.contentOffset.y
        let visibleTop = offset + insets.top
        let visibleBottom = offset + collectionView.bounds.height - insets.bottom
        if slotY >= visibleTop - 0.5, slotY + PostDetailViewController.landingRowAllowance <= visibleBottom { return nil }
        let minY = -insets.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        let wanted = slotY - insets.top - (visibleBottom - visibleTop) / 3
        let y = min(max(wanted, minY), maxY)
        guard abs(y - offset) > 0.5 else { return nil }
        return CGPoint(x: collectionView.contentOffset.x, y: y)
    }

    /// The viewer's comment that just landed, until its row has arrived.
    var arrivingCommentID: String?

    /// The viewer's new comment arrives with the comment row's effect — the
    /// bounce-in (#920) — rather than appearing on UIKit's insert alone.
    ///
    /// ⚠️ PLAYED AFTER THE APPLY, never from the cell registration: the data
    /// source dequeues cells inside an apply UIKit runs without animation, and
    /// a `UIView.animate` issued there is swallowed (see `revealLoadedRow`).
    /// Laying out first gives the inserted row its cell in this same turn.
    private func playArrival(ofPostedComment id: String) {
        collectionView.layoutIfNeeded()
        guard let indexPath = streamDataSource.indexPath(for: .comment(id)),
              let cell = collectionView.cellForItem(at: indexPath),
              let row = PostDetailViewController.commentRow(in: cell) else { return }
        row.playAppear(in: cell.contentView)
        #if DEBUG
        debugPlayedArrivals.append(id)
        debugLandingEvents.append("arrive:\(id)")
        #endif
    }

    #if DEBUG
    /// The comments whose arrival played, in order. Tests.
    var debugPlayedArrivals: [String] = []
    /// A posted comment's landing, step by step (#921): `scroll:`, `insert:`,
    /// `arrive:`. Tests.
    var debugLandingEvents: [String] = []
    #endif

    /// The bones step aside and the loaded comments arrive, one after the
    /// other.
    ///
    /// ⚠️ **THIS USED TO BE A FADE NOBODY SAW, TWICE OVER.** The flag that
    /// asked new cells to fade was cleared by a `DispatchQueue.main.async` —
    /// which drains BEFORE the commit's layout pass, the one that dequeues
    /// the cells — so no row ever read it; and the staged fade used
    /// `.beginFromCurrentState`, which runs 1 → 1 on a reused cell. What the
    /// viewer got was UIKit's own insert animation: the bones gone in a frame
    /// and the rows up in two or three (measured at 30 fps, reported from a
    /// device as "ils apparaissent directement").
    ///
    /// Now: the visible bones are lifted off as snapshots and faded out; the
    /// snapshot is applied WITHOUT UIKit's diff animation, and laid out in
    /// this same pass so every visible row is dequeued while the reveal is
    /// armed; each row then rises into place (`revealLoadedRow`).
    private func revealLoadedComments() {
        fadeOutVisibleBones()
        revealsLoadedRows = true
        applyStream(animated: false)
        collectionView.layoutIfNeeded()
        revealsLoadedRows = false
        playStagedReveal()
    }

    /// The comments already on screen arrive as a reveal — for a panel
    /// mounted over a stand-in that was showing bones where they are
    /// (`SnapFeedViewController.installRestingPanel`). A panel still loading
    /// shows its own bones and reveals when they are replaced; the caption
    /// row never moves (it is on the same pixels as the stand-in's).
    func revealVisibleComments() {
        guard commentsLoaded, collectionView.window != nil else { return }
        let rows = collectionView.indexPathsForVisibleItems.sorted()
            .compactMap { indexPath -> UIView? in
                guard let item = streamDataSource.itemIdentifier(for: indexPath) else { return nil }
                switch item {
                case .comment, .seam: return collectionView.cellForItem(at: indexPath)?.contentView
                default: return nil
                }
            }
        let pills = collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: DayPillHeaderView.elementKind
        ).compactMap {
            collectionView.supplementaryView(forElementKind: DayPillHeaderView.elementKind, at: $0)
        }
        guard !rows.isEmpty else { return }
        revealsLoadedRows = true
        (pills + rows).forEach(revealLoadedRow)
        revealsLoadedRows = false
        playStagedReveal()
    }

    private func fadeOutVisibleBones() {
        guard collectionView.window != nil else { return }
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  case .skeletonPlaceholder = streamDataSource.itemIdentifier(for: indexPath),
                  let ghost = cell.snapshotView(afterScreenUpdates: false)
            else { continue }
            ghost.frame = cell.frame
            ghost.isUserInteractionEnabled = false
            collectionView.addSubview(ghost)
            UIView.animate(withDuration: PostDetailViewController.boneFade, delay: 0, options: [.curveEaseOut]) {
                ghost.alpha = 0
            } completion: { _ in
                ghost.removeFromSuperview()
            }
        }
    }

    /// Stages one row of the reveal (`revealLoadedComments`) at its start:
    /// invisible, a little low and a little small. Driven on the CONTENT view,
    /// so the layout's own attributes on the cell are never fought.
    ///
    /// ⚠️ **STAGED HERE, PLAYED LATER.** The cells are dequeued INSIDE the
    /// data source's apply, which UIKit runs without animation — a
    /// `UIView.animate` issued from the cell registration there is swallowed,
    /// and the rows simply appeared (measured: three rows staged, none seen
    /// fading). `playStagedReveal` animates them once the apply is over.
    private func revealLoadedRow(_ target: UIView) {
        guard revealsLoadedRows else { return }
        target.alpha = 0
        if !MotionPreference.reducesMotion {
            target.transform = CGAffineTransform(translationX: 0, y: PostDetailViewController.revealRise)
                .scaledBy(x: PostDetailViewController.revealScale, y: PostDetailViewController.revealScale)
        }
        stagedReveals.append(target)
    }

    /// Plays the staged rows into place: faded up from nothing, risen and
    /// scaled on a soft spring, in stagger order (fade alone under Reduce
    /// Motion — nothing was moved).
    ///
    /// ⚠️ NOT `.beginFromCurrentState`: it reads the from-value off the
    /// PRESENTATION layer, where a reused view is still at rest — the start
    /// staged in this same turn is not there yet, and the animation would run
    /// end → end, invisibly.
    private func playStagedReveal() {
        let staged = stagedReveals
        stagedReveals.removeAll()
        for (order, target) in staged.enumerated() {
            UIView.animate(
                withDuration: 0.5,
                delay: PostDetailViewController.revealLead + PostDetailViewController.revealStagger * Double(min(order, PostDetailViewController.revealStaggerCap)),
                usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                options: [.allowUserInteraction]
            ) {
                target.alpha = 1
                target.transform = .identity
            }
        }
    }

    private func configureStreamDataSource() {
        // The cell owns its row for its whole life; this only re-points it.
        // No subview teardown, no view construction, no recognizer or
        // interaction allocation per dequeue — the scroll path does layout
        // and text, and nothing else.
        let commentCell = UICollectionView.CellRegistration<CommentCell, String> {
            [weak self] cell, indexPath, commentID in
            guard let self, let model = self.streamModels[commentID] else { return }
            self.configureCommentRow(cell.row, with: model)
            self.revealLoadedRow(cell.contentView)
        }
        // The same row, liftable (text pages): no menu of its own, the
        // stream's `rowContextMenu` lifts it.
        let liftableCommentCell = UICollectionView.CellRegistration<ThreadRowCell, String> {
            [weak self] cell, indexPath, commentID in
            guard let self, let model = self.streamModels[commentID] else { return }
            self.configureCommentRow(cell.row, with: model)
            self.revealLoadedRow(cell.contentView)
        }
        let seamCell = UICollectionView.CellRegistration<UICollectionViewCell, StreamItem> {
            [weak self] cell, _, item in
            guard let self, case .seam(let kind, let parentID) = item else { return }
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let seam = self.makeSeamRow(kind: kind, parentID: parentID)
            seam.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(seam)
            NSLayoutConstraint.activate([
                seam.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                seam.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                seam.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                seam.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.lg),
            ])
        }
        let skeletonCell = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, index in
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let row = CommentSkeletonRowView(index: index)
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                row.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.lg),
            ])
        }
        // The empty stream gets the app's shared empty PAGE: the comments ARE
        // the page, so its emptiness is the page's emptiness, and that is
        // exactly what `EmptyStateView` is for.
        // The height is decided HERE, once, from geometry that is already
        // final on frame 0 — `CommentsEmptyPageCell` then returns it
        // unchanged for the life of the configuration. Nothing recomputes
        // it later, which is what stops the block moving at the end of the
        // presentation.
        let emptyPageCell = UICollectionView.CellRegistration<CommentsEmptyPageCell, StreamItem> {
            [weak self] cell, _, _ in
            let fit = self?.currentEmptyPageFit() ?? EmptyPageFit(
                copy: PostDetailViewController.commentsEmptyPageCopy,
                height: SnapCommentsLayout.emptyPageFallbackHeight,
                blockOffset: 0
            )
            cell.configure(
                symbolName: fit.copy.symbol,
                title: fit.copy.title,
                subtitle: fit.copy.subtitle,
                height: fit.height,
                blockOffset: fit.blockOffset,
                actionTitle: fit.copy.actionTitle,
                action: fit.copy.actionTitle == nil ? nil : { [weak self] in self?.retryCommentsFromPage() }
            )
            // What the cell was actually given — see `applyStream`.
            self?.renderedEmptyPageFit = fit
        }
        let captionCell = UICollectionView.CellRegistration<CaptionBubbleCell, StreamItem> {
            [weak self] cell, _, _ in
            guard let self else { return }
            if let post = self.latestPost {
                cell.configure(
                    with: post,
                    imagePipeline: self.imagePipeline,
                    likeCount: self.captionLikeCount
                )
            } else if let seed = self.seededCaption {
                cell.configureSeed(
                    caption: seed.text,
                    timestamp: seed.timestamp,
                    authorName: self.seededAuthor?.name ?? "",
                    monogram: self.seededAuthor?.monogram ?? "",
                    avatarURL: self.seededAuthor?.avatarURL,
                    likeCount: self.captionLikeCount,
                    imagePipeline: self.imagePipeline
                )
            } else {
                return
            }
            cell.onAvatarTap = { [weak self] in self?.viewModel.didTapAuthor() }
        }
        let tierEndCell = UICollectionView.CellRegistration<UICollectionViewCell, StreamItem> { cell, _, _ in
            guard cell.contentView.constraints.isEmpty else { return }
            cell.contentView.heightAnchor.constraint(equalToConstant: Self.tierEndHeight).isActive = true
        }
        let threadChrome = threadChrome
        streamDataSource = UICollectionViewDiffableDataSource<StreamSection, StreamItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .caption:
                return collectionView.dequeueConfiguredReusableCell(using: captionCell, for: indexPath, item: item)
            case .emptyState:
                return collectionView.dequeueConfiguredReusableCell(using: emptyPageCell, for: indexPath, item: item)
            case .skeletonPlaceholder(let index):
                return collectionView.dequeueConfiguredReusableCell(using: skeletonCell, for: indexPath, item: index)
            case .comment(let id):
                return threadChrome
                    ? collectionView.dequeueConfiguredReusableCell(using: liftableCommentCell, for: indexPath, item: id)
                    : collectionView.dequeueConfiguredReusableCell(using: commentCell, for: indexPath, item: id)
            case .seam:
                return collectionView.dequeueConfiguredReusableCell(using: seamCell, for: indexPath, item: item)
            case .tierEnd:
                return collectionView.dequeueConfiguredReusableCell(using: tierEndCell, for: indexPath, item: item)
            }
        }
        guard groupsByDay else { return }
        let dayPill = UICollectionView.SupplementaryRegistration<DayPillHeaderView>(
            elementKind: DayPillHeaderView.elementKind
        ) { [weak self] pill, _, indexPath in
            guard let self,
                  case .day(let day) = self.streamDataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            pill.configure(title: DayTitleFormatter.title(for: day))
            // The day's pill arrives with the rows it heads.
            self.revealLoadedRow(pill)
        }
        streamDataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: dayPill, for: indexPath)
        }
    }

    /// The stream's sections: today's single `.main` whenever the chrome is
    /// off, and — with it on — the caption in `.main`, then one `.day` per day
    /// that a THREAD began on. A reply stays with its thread, under the day
    /// the thread started, so a thread never splits across two pills.
    ///
    /// Only under Recent, with comments loaded and some to show: a Popular
    /// rank, a skeleton and the empty page have no chronology to pin days over.
    private func streamSections() -> [(section: StreamSection, items: [StreamItem])] {
        let items = streamItems()
        guard groupsByDay, kind == .recent, commentsLoaded, !latestComments.isEmpty else {
            return [(.main, items)]
        }
        let calendar = Calendar.current
        var sections: [(section: StreamSection, items: [StreamItem])] = [(.main, [])]
        var indexByDay: [Date: Int] = [:]
        var current = 0
        for item in items {
            if case .comment(let id) = item, let model = streamModels[id], model.parentID == nil,
               let createdAt = model.createdAt {
                let day = calendar.startOfDay(for: createdAt)
                if let existing = indexByDay[day] {
                    // A day that already has a pill keeps it — a section
                    // identity can appear once in a snapshot.
                    current = existing
                } else {
                    sections.append((.day(day), []))
                    current = sections.count - 1
                    indexByDay[day] = current
                }
            }
            sections[current].items.append(item)
        }
        if sections[0].items.isEmpty { sections.removeFirst() }
        return sections
    }

    /// A text page comment's long-press menu: its own actions — the
    /// row's Share, Block and Report — plus Copy and Select Text. Nil for
    /// everything that is not a comment, the caption included.
    private func rowMenu(at indexPath: IndexPath) -> UIMenu? {
        guard case .comment(let id) = streamDataSource.itemIdentifier(for: indexPath),
              let model = streamModels[id] else { return nil }
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = model.body
            // Said (#803): nothing on screen shows a copy.
            self?.host.confirmCopied()
        }
        let select = UIAction(title: "Select Text", image: UIImage(systemName: "text.magnifyingglass")) {
            [weak self] _ in
            guard let self, let current = self.streamDataSource.indexPath(for: .comment(id)) else { return }
            self.rowContextMenu.beginTextSelection(at: current)
        }
        let share = UIAction(title: "Share Comment", image: AppSymbol.share.image()) {
            [weak self] _ in self?.host.presentCommentShare(model)
        }
        // ⚠️ NO MODERATION ROWS UNTIL THEY DO SOMETHING (#801). Block and
        // Report used to sit here as `{ _ in }` no-ops: for a safety action
        // the user believes something was filed. There is no comment report
        // flow (`ReportSubject` has no comment case), so the same builder
        // as the row's own menu draws nothing for the unset seams.
        let moderation = CommentRowView.moderationMenu(onBlock: nil, onReport: nil).map { [$0] } ?? []
        guard model.canReview else { return UIMenu(children: [copy, select, share] + moderation) }
        let review = CommentRowView.reviewActions { [weak self] approve in
            self?.viewModel.reviewHeldComment(id, approve: approve)
        }
        return UIMenu(children: [review, copy, select, share] + moderation)
    }

    private func streamItems() -> [StreamItem] {
        var items: [StreamItem] = []
        // The caption leads the stream — item #0, above the skeletons as well
        // as above the comments, so it is on screen from the first frame and
        // never pops in behind a shimmer.
        //
        // Recent's caption is the oldest message (#2007): at the top of the
        // history once there is nothing older to load.
        if latestPost?.hasCaption == true || seededCaption != nil,
           kind == .popular || !viewModel.hasOlderComments {
            items.append(.caption)
        }
        guard commentsLoaded else {
            // The initial fetch renders as a skeleton stream (the
            // messages screens' doctrine — shimmering placeholder rows,
            // never a spinner); hydration cross-dissolves into the same
            // row geometry via the diffable apply. The count is VIEWPORT
            // MATH, not a constant: enough rows to cover this device's
            // height down to the input bar (the list clips the excess),
            // so no form factor — SE, Pro Max, iPad — strands blank
            // space under a too-short shimmer block.
            //
            // ⚠️ ON THE KIT'S TIMING (#1770): no bones before its delay, and
            // past 10 s the empty page's row says "taking longer".
            switch commentsGate.loading() {
            case .nothing:
                return items
            case .takingLonger:
                items.append(.emptyState)
                return items
            case .bones:
                break
            }
            let viewport = collectionView.bounds.height > 0
                ? collectionView.bounds.height
                : view.bounds.height
            let count = SnapCommentsLayout.skeletonPlaceholderCount(
                viewportHeight: viewport, knownComments: knownCommentCount
            )
            items.append(contentsOf: (0..<count).map(StreamItem.skeletonPlaceholder))
            return items
        }
        guard !latestComments.isEmpty else {
            items.append(.emptyState)
            return items
        }
        let ordered = kind == .recent ? Self.conversationOrder(latestComments) : latestComments
        var comments: [StreamItem] = []
        for item in CommentThreadPresentation.items(from: ordered, expanded: expandedReplyParents) {
            switch item {
            case .comment(let model):
                comments.append(.comment(model.id))
            case .viewMoreReplies(let parentID, let hiddenCount):
                comments.append(.seam(.expand(hidden: hiddenCount), parentID: parentID))
            case .collapseReplies(let parentID):
                comments.append(.seam(.collapse, parentID: parentID))
            }
        }
        guard readsTiersNow else { return items + comments }
        return cutToTiers(comments, lead: items)
    }

    // MARK: - Tiers (#2042)

    /// Whether the stream reads in tiers (#2042, the owner 2026-11-02): set by
    /// a host whose page stands in a vertical feed, where the edge of what is
    /// shown hands the swipe to the screen (the next post, the close). Off,
    /// the stream scrolls through everything it holds, as before.
    var readsInTiers = false {
        didSet {
            guard readsInTiers != oldValue, hasAppliedStream else { return }
            applyStream(animated: false)
        }
    }

    /// Whether the tiers cut what is shown now: reading in tiers, with a room
    /// to measure them against.
    private var readsTiersNow: Bool { readsInTiers && tierViewport > 0 }

    /// The room one tier is measured against: the stream's settled room,
    /// less its section's own insets.
    private var tierViewport: CGFloat { availableStreamHeight - streamSectionVerticalInsets }

    /// The furthest thread shown so far, from the stream's start: what is
    /// shown only grows — a comment arriving above it never pushes a thread
    /// the reader saw back out.
    private var furthestRevealedThread: String?
    /// The threads of the last cut, from the stream's start, and how many of
    /// them are shown.
    private var tierThreads: [[StreamItem]] = []
    private(set) var revealedThreadCount = 0
    /// The threads past what is shown, and their height.
    var hiddenThreadCount: Int { max(0, tierThreads.count - revealedThreadCount) }
    private var hiddenHeight: CGFloat = 0
    /// A "More" tapped while the next tier was still loading: revealed when
    /// it lands.
    private var revealsWhenLoaded = false

    /// The drag that started at the stream's bottom edge heading up: it moves
    /// the feed to the next post, as the composer's swipe does, while the
    /// stream stays at its edge. Nil for any other drag.
    private var pageDrive: (edge: CGFloat, handler: (CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)?
    /// Set while the stream's offset is put back at its edge.
    private var isHoldingEdge = false

    /// `comments` cut to what the tiers show (Popular from its top, Recent
    /// from its newest), after `lead` (the caption — Recent's only once its
    /// whole history is shown).
    private func cutToTiers(_ comments: [StreamItem], lead: [StreamItem]) -> [StreamItem] {
        let threads = CommentTiers.threads(of: comments) { item in
            if case .comment(let id) = item { return streamModels[id]?.parentID == nil }
            return false
        }
        let fromStart = kind == .popular ? threads : Array(threads.reversed())
        var heights = fromStart.map(threadHeight)
        // The tier's end room is part of the tier.
        var leadHeight = (kind == .popular ? lead.reduce(0) { $0 + rowHeight($1) } : 0) + Self.tierEndHeight
        // Recent's day pills (#757): one over each thread that starts a day,
        // and one over the topmost thread shown, whose day began further up.
        if kind == .recent, groupsByDay {
            let pill = measuredDayPillHeight
            leadHeight += pill
            let days = threads.map { thread -> Date? in
                guard case .comment(let id) = thread.first, let created = streamModels[id]?.createdAt else { return nil }
                return Calendar.current.startOfDay(for: created)
            }
            for index in days.indices where index > 0 && days[index] != days[index - 1] {
                heights[threads.count - 1 - index] += pill
            }
        }
        var revealed = CommentTiers.firstTierCount(heights: heights, viewport: tierViewport, lead: leadHeight)
        if let furthest = furthestRevealedThread,
           let index = fromStart.firstIndex(where: { Self.threadID($0) == furthest }) {
            revealed = max(revealed, index + 1)
        }
        if revealed > 0 { furthestRevealedThread = Self.threadID(fromStart[revealed - 1]) }
        tierThreads = fromStart
        revealedThreadCount = revealed
        hiddenHeight = heights.dropFirst(revealed).reduce(0, +)
        let shown = fromStart.prefix(revealed)
        let end: [StreamItem] = hiddenThreadCount > 0 || sourceHasMore ? [.tierEnd] : []
        switch kind {
        case .popular:
            return lead + shown.flatMap { $0 } + end
        case .recent:
            return (end.isEmpty && hiddenThreadCount == 0 ? lead : end) + shown.reversed().flatMap { $0 }
        }
    }

    /// The tier's end room: the button's height and a breath either side.
    static let tierEndHeight: CGFloat = 52

    /// A day pill's height, as the layout draws it — measured again with the
    /// rows (`rowHeight`).
    private var dayPillHeight: CGFloat? = nil
    private var measuredDayPillHeight: CGFloat {
        if let dayPillHeight { return dayPillHeight }
        let pill = DayPillHeaderView()
        pill.configure(title: "Today")
        let height = ceil(pill.systemLayoutSizeFitting(
            CGSize(width: streamRowWidth, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height)
        dayPillHeight = height
        return height
    }

    /// A thread's identity: its first row's comment.
    static func threadID(_ thread: [StreamItem]) -> String? {
        switch thread.first {
        case .comment(let id): return id
        case .seam(_, let parentID): return parentID
        default: return nil
        }
    }

    private func threadHeight(_ thread: [StreamItem]) -> CGFloat {
        thread.reduce(0) { $0 + rowHeight($1) }
    }

    /// The rows' measured heights at the rows' width — a row keeps its
    /// height for as long as its identity and the width hold.
    private var rowHeights: [StreamItem: CGFloat] = [:]
    private var rowHeightsWidth: CGFloat = 0
    private var rowHeightsCategory: UIContentSizeCategory?
    /// The caption's, kept apart: its text arrives late (the seed, then the post).
    private var captionHeight: (caption: String, height: CGFloat)?

    /// A row's height as the layout will draw it, measured through the same
    /// cell class at the rows' width — never displayed.
    private func rowHeight(_ item: StreamItem) -> CGFloat {
        let width = streamRowWidth
        guard width > 0 else { return 0 }
        // A width or a text size of its own: every height is measured again.
        let category = traitCollection.preferredContentSizeCategory
        if abs(width - rowHeightsWidth) > 0.5 || category != rowHeightsCategory {
            rowHeights = [:]
            captionHeight = nil
            dayPillHeight = nil
            rowHeightsWidth = width
            rowHeightsCategory = category
        }
        if case .caption = item {
            let caption = latestPost?.caption ?? seededCaption?.text ?? ""
            if let known = captionHeight, known.caption == caption { return known.height }
            let height = captionRowHeight(width: width)
            captionHeight = (caption, height)
            return height
        }
        if let known = rowHeights[item] { return known }
        let height: CGFloat
        switch item {
        case .comment(let id):
            guard let model = streamModels[id] else { return 0 }
            height = measure(sizingCommentCell, width: width) { cell in
                guard let row = PostDetailViewController.commentRow(in: cell) else { return }
                row.variant = .comment
                row.configure(with: model)
                row.setLiked(model.isLiked, count: model.likeCount)
            }
        case .seam(let kind, let parentID):
            let seam = CommentThreadToggleRow(kind: kind, parentID: parentID)
            seam.bounds.size.width = width
            height = ceil(seam.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height) + Spacing.lg
        default:
            height = 0
        }
        rowHeights[item] = height
        return height
    }

    /// The comment row's cell, offscreen, for `rowHeight`.
    private lazy var sizingCommentCell: UICollectionViewCell = threadChrome ? ThreadRowCell() : CommentCell()

    private func measure(_ cell: UICollectionViewCell, width: CGFloat, configure: (UICollectionViewCell) -> Void) -> CGFloat {
        configure(cell)
        cell.bounds.size.width = width
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        return ceil(cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    /// Whether the stream's source holds more than it has loaded.
    private var sourceHasMore: Bool {
        kind == .popular ? viewModel.hasMorePopularComments : viewModel.hasOlderComments
    }

    /// Whether there is a next tier to show: threads held past what is shown,
    /// or more to load.
    var hasNextTier: Bool { readsTiersNow && (hiddenThreadCount > 0 || sourceHasMore) }

    /// The next tier's comments, asked ahead (#2042): whenever what is held
    /// past what is shown is less than a later tier's ceiling.
    private func loadNextTierAhead() {
        guard readsTiersNow, sourceHasMore,
              hiddenHeight < tierViewport * CommentTiers.laterTierCeiling else { return }
        switch kind {
        case .recent: viewModel.loadMoreComments()
        case .popular: viewModel.loadMorePopularComments()
        }
    }

    /// "More" (#2042): the next tier comes in, and the stream scrolls into
    /// it — Popular down to its first thread, Recent up over its newest.
    func revealNextTier(animated: Bool) {
        guard readsTiersNow else { return }
        guard hiddenThreadCount > 0 else {
            // Still on its way: shown when it lands.
            revealsWhenLoaded = sourceHasMore
            loadNextTierAhead()
            return
        }
        revealsWhenLoaded = false
        let hidden = Array(tierThreads.dropFirst(revealedThreadCount))
        let count = CommentTiers.nextTierCount(heights: hidden.map(threadHeight), viewport: tierViewport)
        guard count > 0, let first = hidden.first else { return }
        furthestRevealedThread = Self.threadID(hidden[count - 1])
        applyStream(animated: false)
        collectionView.layoutIfNeeded()
        // Where the stream goes: Popular's new tier from its first thread at
        // the top, Recent's from its newest at the bottom.
        func target() -> CGFloat? {
            let insets = collectionView.adjustedContentInset
            switch kind {
            case .popular:
                guard let item = first.first, let path = streamDataSource.indexPath(for: item),
                      let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return nil }
                return min(frame.minY - insets.top, tailOffset)
            case .recent:
                guard let item = first.last, let path = streamDataSource.indexPath(for: item),
                      let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return nil }
                return max(frame.maxY - collectionView.bounds.height + insets.bottom, -insets.top)
            }
        }
        // Laid out at its destination before the flight: rows that first come
        // on screen inside an animated scroll would refine their estimated
        // heights under it. The stream then goes back to where it was,
        // holding what the reader sees, and flies there.
        let anchor = visibleAnchor()
        suppressesPaging = true
        for _ in 0..<3 {
            guard let destination = target() else { break }
            collectionView.contentOffset.y = destination
            collectionView.layoutIfNeeded()
        }
        suppressesPaging = false
        if let anchor { hold(anchor) }
        holdsRest = false
        guard let destination = target() else { return syncMoreButton() }
        scrollProgrammatically(to: destination, animated: animated && collectionView.window != nil)
        syncMoreButton()
    }

    /// Recent as a conversation (#2007): the view model's threads, newest
    /// first, turned oldest first. A thread keeps its replies under it, in
    /// their own order. Pure, for tests.
    static func conversationOrder(_ comments: [CommentDisplayModel]) -> [CommentDisplayModel] {
        var threads: [[CommentDisplayModel]] = []
        for comment in comments {
            if comment.parentID == nil || threads.isEmpty {
                threads.append([comment])
            } else {
                threads[threads.count - 1].append(comment)
            }
        }
        return threads.reversed().flatMap { $0 }
    }

    func applyStream(
        animated: Bool, reconfiguring: [StreamItem] = [], completion: (() -> Void)? = nil
    ) {
        var snapshot = NSDiffableDataSourceSnapshot<StreamSection, StreamItem>()
        let sections = streamSections()
        for (section, items) in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        let shown = Set(streamDataSource.snapshot().itemIdentifiers)
        let stale = reconfiguring.filter { shown.contains($0) && snapshot.indexOfItem($0) != nil }
        if !stale.isEmpty { snapshot.reconfigureItems(stale) }
        if streamPolicy.update(sections.map(\.section)) {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        // ⚠️ THE EMPTY PAGE KEEPS ITS IDENTITY, so nothing re-asks it — and what
        // it should say, or how tall it should be, can change under it: a
        // draft becoming a post, or a caption arriving after an empty stream
        // already sized the page without one (the page then scrolled by
        // exactly the caption's height). Reconfigured in this same apply, so
        // there is no frame of the stale one — and only on a real change.
        if let rendered = renderedEmptyPageFit,
           snapshot.itemIdentifiers.contains(.emptyState),
           streamDataSource.snapshot().itemIdentifiers.contains(.emptyState),
           !rendered.matches(currentEmptyPageFit()) {
            snapshot.reconfigureItems([.emptyState])
        }
        // ⚠️ WHERE IT STANDS STAYS (#2007): a stream at its resting end stays
        // there, and one the reader scrolled keeps the rows on screen where
        // they are — older pages land above Recent, the viewer's own above
        // Popular, a stream off screen settles unseen.
        let anchor = holdsRest || !hasAppliedStream ? nil : visibleAnchor()
        // ⚠️ OFF SCREEN, NOTHING ANIMATES: the other tab settles unseen, ready
        // when it comes in.
        let animated = animated && host.stream === self
        hasAppliedStream = true
        pagingItems = pagingItems(of: snapshot.itemIdentifiers)
        suppressesPaging = kind == .recent && holdsRest
        #if DEBUG
        debugLastApplyAnimated = animated && anchor == nil
        #endif
        streamDataSource.apply(snapshot, animatingDifferences: animated && anchor == nil) { completion?() }
        suppressesPaging = false
        // The slack follows the content (#1799): a comment, a page of them,
        // a sort or a thread's replies only change its height.
        syncBottomAnchor(animated: animated)
        if let anchor {
            hold(anchor)
        } else if holdsRest, kind == .recent {
            pinToTail(animated: animated && collectionView.window != nil)
        }
        if readsTiersNow {
            if revealsWhenLoaded, hiddenThreadCount > 0 { return revealNextTier(animated: animated) }
            loadNextTierAhead()
            syncMoreButton()
        }
    }

    /// The rows that ask for the next page when one of them comes on screen
    /// (#589), early enough that it usually lands before the viewer gets
    /// there: Popular's last few, Recent's first few — its older history is
    /// above it (#2007).
    private var pagingItems: Set<StreamItem> = []

    private func pagingItems(of items: [StreamItem]) -> Set<StreamItem> {
        let rows = items.filter {
            switch $0 {
            case .comment, .seam: return true
            default: return false
            }
        }
        let count = PostDetailViewController.nearEndRowCount
        return Set(kind == .recent ? rows.prefix(count) : rows.suffix(count))
    }

    /// The empty page's Try Again: a failed first page, or one still out
    /// past 10 s (#1770) — which a new read supersedes.
    private func retryCommentsFromPage() {
        guard kind == .recent else { return viewModel.retryPopularComments() }
        guard !commentsLoaded, commentsGate.isTakingLonger else { return viewModel.retryComments() }
        commentsGate.retry()
        applyStream(animated: false)
        viewModel.retryCommentsAfterWait()
    }

    private var emptyPageCopy: EmptyPageCopy {
        if commentsFailed { return PostDetailViewController.commentsFailedPageCopy(commentsFailureText) }
        if !commentsLoaded, commentsGate.isTakingLonger { return PostDetailViewController.commentsTakingLongerPageCopy }
        return viewModel.isDraft ? PostDetailViewController.draftEmptyPageCopy : PostDetailViewController.commentsEmptyPageCopy
    }

    /// What the empty page was last configured with.
    private struct EmptyPageFit {
        let copy: EmptyPageCopy
        let height: CGFloat
        /// See `emptyPageBlockOffset`.
        let blockOffset: CGFloat

        /// Within half a point is the same page: the measurement is arithmetic
        /// on fonts, and a re-configure for a rounding difference would be a
        /// jump for nothing.
        func matches(_ other: EmptyPageFit) -> Bool {
            copy == other.copy
                && abs(height - other.height) < 0.5
                && abs(blockOffset - other.blockOffset) < 0.5
        }
    }

    private var renderedEmptyPageFit: EmptyPageFit?

    /// Re-asks every row how tall it wants to be.
    ///
    /// `reconfigureItems`, not `invalidateLayout`: UIKit caches a
    /// self-sizing cell's preferred attributes, and invalidating the layout
    /// re-runs the layout against that same cached size. Reconfiguring is
    /// what actually re-asks the cell.
    ///
    /// This is for width CHANGES only. It used to also run once after the
    /// first apply, papering over rows that measured against an unsettled
    /// width; `CaptionBubbleCell.preferredLayoutAttributesFitting` measures
    /// against the authoritative width now, so there is nothing left to
    /// paper over.
    private func remeasureStream() {
        var snapshot = streamDataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        streamDataSource.apply(snapshot, animatingDifferences: false)
        syncBottomAnchor()
    }

    // MARK: - The empty page's fit

    /// The room the stream will have WHEN IT HAS SETTLED — deliberately not
    /// the room it has right now.
    ///
    /// This is the crux of the jump. Engaging moves the stream's bottom to
    /// the view's bottom (`setEngagedInsets`), so during the transition the
    /// collection view is still GROWING: measured live, the available height
    /// is smaller mid-animation than it ends up, and anything sized from it
    /// has to move when the animation lands. The engaged numbers are known
    /// up front though — they were handed in — so the final geometry is
    /// computable on frame 0 and that is what the empty page is sized
    /// against.
    ///
    /// The view's own height is the stable term (it does not animate); the
    /// collection view's is not, and is used only in the un-engaged case,
    /// where nothing is in flight.
    private var availableStreamHeight: CGFloat {
        if let engaged = engagedStreamInsets {
            return view.bounds.height - engaged.top - engaged.bottom
        }
        let inset = collectionView.adjustedContentInset
        return collectionView.bounds.height - inset.top - inset.bottom
    }

    /// The empty page's fit, resolved SYNCHRONOUSLY.
    ///
    /// The HEIGHT is the room the stream has, less the section's own insets,
    /// less the caption row that sits above it, and never less than the block
    /// the row holds, measured at the row's width (see
    /// `SnapCommentsLayout.emptyPageHeight`). The OFFSET centres that block in
    /// the space a reader sees as empty (see `emptyPageBlockOffset`).
    ///
    /// The caption row is measured here rather than waited for. It is the
    /// only other row in this stream, and a throwaway `CaptionBubbleCell`
    /// answers for it exactly — same cell class, same width, same sizing
    /// path the layout itself would take. Measuring costs one offscreen
    /// layout pass per empty-state configuration; NOT measuring costs a
    /// visible jump, because anything learned after frame 0 arrives as
    /// motion the presentation did not ask for.
    private func currentEmptyPageFit() -> EmptyPageFit {
        let rowWidth = streamRowWidth
        let caption = captionRowHeight(width: rowWidth)
        let block = emptyPageBlockHeight(width: rowWidth)
        let room = availableStreamHeight
        let space = streamSpace(captionHeight: caption)
        // No room at all is no geometry yet: the pre-layout call. Whole
        // points, so the rows never overrun the room by a rounding and leave
        // the page scrolling by a fraction.
        var available: CGFloat? = room > 0
            ? floor(room - streamSectionVerticalInsets - caption)
            : nil
        // ⚠️ THE KEYBOARD TAKES THE STREAM'S ROOM WITHOUT TOUCHING ITS INSETS.
        // It lifts the composer; the insets stay what the resting layout set.
        // So the row stops a breath above the composer WHEREVER IT IS. Sized
        // from the insets alone, the row kept its resting height and the
        // invitation was centred in a middle that had gone behind the keys —
        // reported on an iPhone SE.
        if let space, let roomBased = available {
            available = min(roomBased, floor(space.bottom - Spacing.lg - space.rowTop))
        }
        // Anchored to the bottom (#1799), the page is its block alone: the
        // caption and the invitation rest together just above the composer,
        // the slack above them — not a page filling the room. With no caption
        // (a text post's draft) the invitation stands alone, full height and
        // centred, as an empty conversation's does.
        if anchorsShortStream, engagedStreamInsets != nil, caption > 0 {
            return EmptyPageFit(copy: emptyPageCopy, height: block, blockOffset: 0)
        }
        let height = SnapCommentsLayout.emptyPageHeight(availableHeight: available, blockHeight: block)
        return EmptyPageFit(
            copy: emptyPageCopy,
            height: height,
            blockOffset: emptyPageBlockOffset(rowHeight: height, blockHeight: block, space: space)
        )
    }

    /// How far below its row's centre the empty page's block sits (above,
    /// when negative), so that it is centred in the space a reader SEES as
    /// empty.
    ///
    /// ⚠️ THE ROW IS NOT THAT SPACE. The row fills the stream's content area,
    /// which starts a breath below the header and stops the stream's footer
    /// clearance above the bottom — 16pt short of the composer's top. What a
    /// reader sees as empty runs from the header's foot (or from the caption
    /// row, once there is one) down to the composer. Centred in its row, the
    /// block sat about 24pt above the middle of that space on the Text Post
    /// sheet: measured on an iPhone SE, 30pt of air above it and 47pt below.
    ///
    /// Outside the engaged context the stream does end at the composer's top,
    /// but the row still stops the section's bottom inset short of it: the
    /// space is the row plus its section insets, which centre it
    /// `(bottom − top) / 2` lower. Never more than the row's slack, so the
    /// block never leaves its row.
    private func emptyPageBlockOffset(rowHeight: CGFloat, blockHeight: CGFloat, space: StreamSpace?) -> CGFloat {
        let slack = max(0, (rowHeight - blockHeight) / 2)
        guard let space else { return min(Spacing.lg / 2, slack) }
        let offset = (space.top + space.bottom) / 2 - (space.rowTop + rowHeight / 2)
        return min(max(offset, -slack), slack)
    }

    /// Where the empty page's row starts, and the space a reader SEES as
    /// empty around it.
    private struct StreamSpace {
        let rowTop: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// That space, in this view's coordinates: from the header's foot — or
    /// the caption row's bottom, once there is one — down to the composer's
    /// top, WHEREVER THE COMPOSER IS. Nil outside the engaged context.
    ///
    /// The composer is where `setEngagedInsets` puts it: above the footer
    /// band at rest, its input row lifted to the keyboard's top while it is
    /// up (the column stays below, under the keyboard). Its RESTING heights, a
    /// function of the text size, never its laid-out ones — a bar laid out
    /// after the first fit would change this answer on a later apply, and a
    /// changed answer is a block that jumps.
    private func streamSpace(captionHeight: CGFloat) -> StreamSpace? {
        guard let engaged = engagedStreamInsets, view.bounds.height > 0 else { return nil }
        let rowTop = engaged.top + captionHeight
        let top = captionHeight > 0 ? rowTop : engaged.top - SnapCommentsLayout.streamTopBreath
        let restingBottomInset = engaged.bottom - engagedFooterClearance
        let category = traitCollection.preferredContentSizeCategory
        let composerBottom = view.bounds.height - restingBottomInset - composerRestingGap
        var composerTop = composerBottom - restingComposerHeight(for: category)
        // ⚠️ CONVERTED HERE, NEVER STORED CONVERTED. The sheet grows to its
        // large height FOR the keyboard, which moves this view under a frame
        // that has not moved: a top converted when the notification arrived
        // was 300pt out by the time the page was fitted, and the invitation
        // was pinned to the top of a row squeezed to nothing.
        if composerTracksKeyboard, let covered = keyboardHeightFromBottom {
            let risenRowBottom = view.bounds.height - covered - Spacing.sm
            composerTop = min(composerTop, risenRowBottom - CommentsInputBar.restingInputRowHeight(for: category))
        }
        return StreamSpace(rowTop: rowTop, top: top, bottom: composerTop)
    }

    /// The empty page shown with no caption over it: a text post's draft.
    private var emptyPageStandsAlone: Bool {
        streamDataSource.snapshot().itemIdentifiers.contains(.emptyState)
            && captionRowHeight(width: streamRowWidth) == 0
    }

    /// How tall this view has to be for the empty page's block to show WHOLE
    /// in the visible stream — the inverse of `currentEmptyPageFit`: the
    /// height at which the room the stream has is exactly the block. Nil while
    /// the stream holds no empty page, or before the engaged insets are known.
    /// A sheet sizes its resting detent from it.
    ///
    /// ⚠️ THE TEXT SIZE IS THE CALLER'S. A host asks from its own trait-change
    /// handler, which runs before this controller's traits have caught up:
    /// reading them here measured the block at the size it had just left, and
    /// the sheet did not follow a text size changed while it was open.
    func viewHeightShowingEmptyPage(contentSizeCategory: UIContentSizeCategory) -> CGFloat? {
        guard isViewLoaded, let engaged = engagedStreamInsets,
              streamDataSource.snapshot().itemIdentifiers.contains(.emptyState) else { return nil }
        let rowWidth = streamRowWidth
        guard rowWidth > 0 else { return nil }
        let caption = captionRowHeight(width: rowWidth)
        let block = emptyPageBlockHeight(width: rowWidth, contentSizeCategory: contentSizeCategory)
        // The row has to hold the block…
        let rowHoldsBlock = engaged.top + engaged.bottom + streamSectionVerticalInsets + caption + block
        // …and the block has to clear the composer, which the stream's fixed
        // footer clearance stops covering once the field outgrows one small
        // line (accessibility sizes: the field reaches ~80pt).
        let rowTop = engaged.top + caption
        let restingBottomInset = engaged.bottom - engagedFooterClearance
        let composerHeight = restingComposerHeight(for: contentSizeCategory)
        // The fit keeps the row `Spacing.lg` over the composer
        // (`currentEmptyPageFit`): so does the floor.
        let blockClearsComposer = rowTop + block + Spacing.lg + composerRestingGap + composerHeight
            + restingBottomInset
        return ceil(max(rowHoldsBlock, blockClearsComposer))
    }

    /// The stream's rows are this wide: the stream less the section's side
    /// insets.
    ///
    /// The view's width stands in when the stream has not been laid out yet:
    /// the resting engagement configures rows before the container has run a
    /// pass, and a zero width would measure the caption as zero-height and
    /// hand the empty page the whole viewport.
    private var streamRowWidth: CGFloat {
        let streamWidth = collectionView.bounds.width > 0
            ? collectionView.bounds.width
            : view.bounds.width
        return streamWidth - Spacing.lg * 2
    }

    /// The empty page's block at `width`, in this screen's text size unless
    /// told another.
    private func emptyPageBlockHeight(
        width: CGFloat,
        contentSizeCategory: UIContentSizeCategory? = nil
    ) -> CGFloat {
        let copy = emptyPageCopy
        return CommentsEmptyPageCell.blockHeight(
            symbolName: copy.symbol,
            title: copy.title,
            subtitle: copy.subtitle,
            actionTitle: copy.actionTitle,
            width: width,
            contentSizeCategory: contentSizeCategory ?? traitCollection.preferredContentSizeCategory
        )
    }

    /// The caption row's height at `width`, or 0 when this stream has no
    /// caption row. Sized through the real cell so the answer cannot drift
    /// from what the layout will produce.
    private func captionRowHeight(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let sizingCell = captionSizingCell
        // The SAME count the real row gets: this cell exists to answer how tall
        // the caption row will be, and a closing line it was not given is a
        // line of height it does not reserve.
        if let post = latestPost {
            guard post.hasCaption else { return 0 }
            sizingCell.configure(with: post, imagePipeline: nil, likeCount: captionLikeCount)
        } else if let seed = seededCaption {
            // A SEEDED caption is on screen too — the row the opener handed
            // over before the post loaded — and it takes the same room.
            // Reserving nothing for it made a zero-comment page's empty block
            // too tall by exactly that row, and the page scrolled.
            sizingCell.configureSeed(
                caption: seed.text,
                timestamp: seed.timestamp,
                authorName: seededAuthor?.name ?? "",
                monogram: seededAuthor?.monogram ?? "",
                avatarURL: nil,
                likeCount: captionLikeCount,
                imagePipeline: nil
            )
        } else {
            return 0
        }
        sizingCell.bounds.size.width = width
        sizingCell.contentView.setNeedsLayout()
        sizingCell.contentView.layoutIfNeeded()
        return ceil(sizingCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    /// Offscreen, never in the hierarchy — it exists to be measured. Held
    /// rather than rebuilt so a re-fit costs a layout pass, not a view tree.
    private lazy var captionSizingCell = CaptionBubbleCell()

    func lastDayGoneUnderTheTop() -> Date? {
        guard let streamDataSource, collectionView.window != nil || collectionView.bounds.height > 0 else { return nil }
        let line = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        var passed: Date?
        for (index, section) in streamDataSource.snapshot().sectionIdentifiers.enumerated() {
            guard case .day(let day) = section,
                  let chip = collectionView.layoutAttributesForSupplementaryElement(
                      ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: index)
                  )?.frame
            else { continue }
            // Under the top once its middle is past the stream's edge.
            guard chip.midY <= line else { break }
            passed = day
        }
        return passed
    }

    /// Scrolls to `day`'s chip, landing it just under the stream's top edge.
    ///
    /// ⚠️ UNDER THE EDGE, NOT BELOW IT. The bar's day is the last chip gone
    /// under the top, so a chip landed just below it handed the bar the day
    /// BEFORE: a tap on "Yesterday" retitled the pill "Today", and on the
    /// first day took it away. Under the edge, the chip is what the bar
    /// already says, and that day's first comment opens the stream.
    /// `animated` is false for tests, where nothing drives the animation.
    func scrollToDay(_ day: Date, animated: Bool = true) {
        guard let streamDataSource,
              let section = streamDataSource.snapshot().sectionIdentifiers.firstIndex(of: .day(day)),
              let chip = collectionView.layoutAttributesForSupplementaryElement(
                  ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: section)
              )?.frame
        else { return }
        let insets = collectionView.adjustedContentInset
        let maxOffset = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        let offset = min(max(chip.maxY - insets.top, -insets.top), maxOffset)
        scrollProgrammatically(to: offset, animated: animated)
    }

    /// The stream's days, in order, with the section each heads. Tests.
    var debugStreamDays: [(day: Date, section: Int)] {
        guard let streamDataSource else { return [] }
        return streamDataSource.snapshot().sectionIdentifiers.enumerated().compactMap { index, section in
            guard case .day(let day) = section else { return nil }
            return (day, index)
        }
    }

    /// The fold opening: one snapshot apply — UIKit animates the row
    /// insertions natively — and the thread's next page of replies asked
    /// for (#637), which lands as a second apply. Tapped again while the
    /// thread is open, the seam asks for the page after.
    private func expandThread(_ parentID: String) {
        expandedReplyParents.insert(parentID)
        applyStream(animated: true)
        viewModel.loadMoreReplies(parentID: parentID)
    }

    /// The fold's inverse: the deletions animate natively, then the
    /// surviving view-more seam is scrolled back into the viewport if the
    /// fold pulled it out (keep-place).
    private func collapseThread(_ parentID: String) {
        expandedReplyParents.remove(parentID)
        applyStream(animated: true) { [weak self] in
            guard let self else { return }
            let items = self.streamDataSource.snapshot().itemIdentifiers
            // Looked up through the data source, not as an index into section
            // 0: with day pills on, the seam lives in whichever day its thread
            // started on.
            guard let seam = items.first(where: { item in
                if case .seam(_, let id) = item { return id == parentID }
                return false
            }), let indexPath = self.streamDataSource.indexPath(for: seam) else { return }
            if let attributes = self.collectionView.layoutAttributesForItem(at: indexPath) {
                self.isScrollingProgrammatically = true
                self.collectionView.scrollRectToVisible(
                    attributes.frame.insetBy(dx: 0, dy: -60), animated: true
                )
            }
        }
    }

    /// Points an EXISTING row at a model and re-wires its seams — the whole
    /// per-dequeue cost of a comment. The image pipeline rides along so the
    /// row can hydrate its own avatar behind its monogram, guarded by the
    /// comment id against a recycled row catching someone else's face.
    private func configureCommentRow(_ row: CommentRowView, with model: CommentDisplayModel) {
        row.variant = .comment
        row.configure(with: model, imagePipeline: imagePipeline)
        row.onAvatarTap = { [weak self] in
            self?.viewModel.didTapCommentAuthor(commentID: model.id)
        }
        row.onReplyTap = { [weak self] in
            guard let self else { return }
            self.host.retireKeyboardOr { self.host.enterReplyState(for: model) }
        }
        row.onShare = { [weak self] in self?.host.presentCommentShare(model) }
        row.onReview = model.canReview
            ? { [weak self] approve in self?.viewModel.reviewHeldComment(model.id, approve: approve) }
            : nil
        // Moderation seams: the menu is the honest affordance; the
        // block/report mutations wait on a moderation backend (the
        // repost/save posture).
        row.onBlock = nil
        row.onReport = nil
        // Like truth lives in the VIEW MODEL, from the server (#637): a tap
        // stakes a point and re-emits, and the row is reconfigured in place
        // (`renderComments`) — re-ranking waits for the next sort, never
        // yanking the row from under the finger.
        row.setLiked(model.isLiked, count: model.likeCount)
        row.onLikeTap = { [weak self] in
            guard let self else { return }
            MemberGates.perform(.comment, from: self.host) { [weak self] in
                // Turned on at the optimistic flip (#1885).
                if self?.viewModel.likeComment(commentID: model.id) == true { Haptics.play(.toggleOn) }
            }
        }
    }

    private func makeSeamRow(kind: CommentThreadToggleRow.Kind, parentID: String) -> CommentThreadToggleRow {
        let seam = CommentThreadToggleRow(kind: kind, parentID: parentID)
        switch kind {
        case .expand:
            seam.onTap = { [weak self] in self?.expandThread(parentID) }
        case .collapse:
            seam.onTap = { [weak self] in self?.collapseThread(parentID) }
        }
        return seam
    }

}

// MARK: - Interactive pull-down dismissal

extension CommentStream: UICollectionViewDelegate {
    /// Paging, not dismissal: one of the stream's last rows coming on screen
    /// asks for the next page of comments (#589).
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard !suppressesPaging, !readsTiersNow, let item = streamDataSource.itemIdentifier(for: indexPath),
              pagingItems.contains(item) else { return }
        switch kind {
        case .recent: viewModel.loadMoreComments()
        case .popular: viewModel.loadMorePopularComments()
        }
    }

    /// The list's OVERSHOOT past its top drives the collapse back to the
    /// media layout, continuously and in both directions.
    ///
    /// Reading `contentOffset` rather than the pan is what keeps the two
    /// surfaces welded: the rubber band and the fade are the same number, so
    /// the content cannot slide while the layer sits still. It also makes
    /// the cancel free — when a released pull springs back, UIKit animates
    /// the offset home and these callbacks walk the transition back to rest
    /// with it, no separate animation to write or to keep in sync.
    ///
    /// Arming is unconditional by construction: overshoot exists only at the
    /// top, so a drag anywhere else reports zero and drives nothing.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if threadChrome { rowContextMenu.endTextSelection() }
        // INTENT, decided once per drag: only a gesture that starts at the
        // top is a dismissal. A drag that begins mid-list and scrolls up
        // into the top is someone reading — it still bounces, because that
        // is UIKit's own behaviour and the content genuinely ran out, but it
        // drives nothing. Arming continuously (which the overshoot alone
        // would do) made every read that reached the top start dissolving
        // the screen.
        //
        // And never while the KEYBOARD is up (asked 2026-10-02): a downward
        // drag then means "put the keyboard away" — the list's interactive
        // dismissal — and must never close the layout under a half-typed
        // comment. Decided at the drag's start, so a drag that carried the
        // keyboard down stays a keyboard drag to its end.
        isPullDismissArmed = PostDetailViewController.armsPullDismiss(
            atTop: scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5,
            keyboardOpen: composeBar.isKeyboardOpen
        )
        beginPageDriveIfAtTheEdge(scrollView)
    }

    // MARK: - The next post from the edge (#2042)

    /// ⚠️ DECIDED AS THE DRAG BEGINS (the owner, 2026-11-02): reading in tiers,
    /// at the bottom edge of what is shown — Popular's tier end, Recent's
    /// newest — with the keyboard down, an upward drag is the screen's. A
    /// fling that reaches the edge mid-drag stops there; the next swipe goes
    /// on, so a reader flicking through comments never leaves the post by
    /// accident.
    private func beginPageDriveIfAtTheEdge(_ scrollView: UIScrollView) {
        pageDrive = nil
        // A reader who moves on no longer waits for a tier still loading
        // (or whose load failed): it is not thrown at them later.
        revealsWhenLoaded = false
        guard readsTiersNow, let handler = composeBar.onPageSwipe, !composeBar.isKeyboardOpen,
              Self.dragGoesToNextPost(
                  atBottomEdge: streamIsAtBottom,
                  velocity: scrollView.panGestureRecognizer.velocity(in: scrollView),
                  translation: scrollView.panGestureRecognizer.translation(in: scrollView)
              ) else { return }
        pageDrive = (tailOffset, handler)
        handler(.began, 0, 0)
    }

    /// Whether a drag beginning now goes to the next post: the stream at its
    /// bottom edge, the finger heading up more than sideways. Pure, for tests.
    static func dragGoesToNextPost(atBottomEdge: Bool, velocity: CGPoint, translation: CGPoint) -> Bool {
        guard atBottomEdge else { return false }
        let upward = velocity.y < 0 || (velocity.y == 0 && translation.y < 0)
        return upward && abs(velocity.y) >= abs(velocity.x)
    }

    /// The page drive's frame: the stream back at its edge, the finger's
    /// travel handed to the feed.
    private func drivePage(_ scrollView: UIScrollView) {
        guard let drive = pageDrive, !isHoldingEdge else { return }
        isHoldingEdge = true
        scrollView.contentOffset.y = drive.edge
        isHoldingEdge = false
        let pan = scrollView.panGestureRecognizer
        drive.handler(.changed, pan.translation(in: scrollView.superview).y, pan.velocity(in: scrollView.superview).y)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard let drive = pageDrive else { return }
        pageDrive = nil
        targetContentOffset.pointee.y = drive.edge
        let pan = scrollView.panGestureRecognizer
        drive.handler(.ended, pan.translation(in: scrollView.superview).y, pan.velocity(in: scrollView.superview).y)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if pageDrive != nil { return drivePage(scrollView) }
        guard !isHoldingEdge else { return }
        syncMoreButton()
        // The reader's own scroll decides whether the stream holds its
        // resting end (#2007): away from it, the rows stay where they are.
        if scrollView.isTracking || scrollView.isDecelerating {
            holdsRest = isAtRest
            host.readerDidScroll()
        }
        host.syncDayUnderHeader()
        // Only the reader's own scroll shows the way back; any move hides it
        // once the text is near again (#1929).
        syncScrollAway(userScroll: scrollView.isTracking || scrollView.isDecelerating)
        guard let onPullDismissDrive, isPullDismissArmed, !isCommittingPullDismiss else { return }
        onPullDismissDrive(.changed, overshoot(of: scrollView), 0)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        guard let onPullDismissDrive, isPullDismissArmed, !isCommittingPullDismiss else { return }
        let pull = overshoot(of: scrollView)
        let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y / 1000
        guard pull > 0, SnapCommentsLayout.shouldCompletePullDismiss(
            progress: SnapCommentsLayout.pullDismissProgress(translation: pull),
            velocity: velocity
        ) else {
            // Below the bar: the bounce springs home and the transition
            // rides it back through `scrollViewDidScroll`. Stay armed until
            // it settles, or the fade would stop wherever it was.
            if !willDecelerate { disarmPullDismiss(scrollView) }
            return
        }
        isCommittingPullDismiss = true
        onPullDismissDrive(.ended, pull, velocity)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        disarmPullDismiss(scrollView)
    }

    /// A posted comment's landing scroll arrived (#921).
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isScrollingProgrammatically = false
        holdsRest = isAtRest
        guard pendingLanding != nil else { return }
        finishLanding(landingGeneration)
    }

    /// Ends the armed window, settling the transition at rest first so a
    /// disarm can never strand it part-way faded.
    private func disarmPullDismiss(_ scrollView: UIScrollView) {
        guard isPullDismissArmed, !isCommittingPullDismiss else { return }
        isPullDismissArmed = false
        onPullDismissDrive?(.changed, 0, 0)
    }

    /// How far past its resting top the list has been pulled, in points.
    /// Zero anywhere else — the resting offset is NEGATIVE here, since the
    /// engaged stream carries a top content inset.
    private func overshoot(of scrollView: UIScrollView) -> CGFloat {
        max(0, -(scrollView.contentOffset.y + scrollView.contentInset.top))
    }
}

/// A gesture delegate that lets its recogniser see only the touches whose
/// location, in the recogniser's view, `accepts`.
private final class TouchFilter: NSObject, UIGestureRecognizerDelegate {
    private let accepts: (CGPoint) -> Bool

    init(accepts: @escaping (CGPoint) -> Bool) {
        self.accepts = accepts
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        accepts(touch.location(in: recognizer.view))
    }
}
