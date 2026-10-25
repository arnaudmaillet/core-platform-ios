import AuthInterface
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreStorage
import MediaCore
import DesignSystem
import FeedInterface
import ProfileInterface
import UIKit

/// The stream's diffable identity space. Content is looked up at cell-
/// configure time (`streamModels`); identity is what animates.
/// `.day` exists only with the text page's chrome on (`threadChrome`): the
/// threads grouped under a pinned pill per day.
private enum StreamSection: Hashable {
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
private enum StreamItem: Hashable {
    /// The post's caption, as the list's first row — a message bubble in
    /// the thread rather than a fixed header above it.
    case caption
    case emptyState
    case skeletonPlaceholder(Int)
    case comment(String)
    case seam(CommentThreadToggleRow.Kind, parentID: String)
}

final class PostDetailViewController: UIViewController {
    /// Where an opened post is recorded — the profile's History tab
    /// (#1344): every post opened counts, here as in the vertical feed.
    var viewHistory: PostViewHistoryStore?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let postID = viewModel.postID { viewHistory?.record(postID.rawValue) }
    }

    private let viewModel: PostDetailViewModel
    private let imagePipeline: ImagePipeline
    /// A TEXT post's resting comments: the threads grouped under pinned day
    /// pills (Recent order only), and the long press lifting the row into its
    /// menu. False for the media pages' comment panels, where nothing below
    /// runs and each row keeps its own menu.
    private let threadChrome: Bool
    /// The threads grouped under a day chip each, in Recent order (#757):
    /// every snap page's comments — media and text — not only a text page's.
    private let groupsByDay: Bool
    private let streamPolicy = StreamSectionPolicy()
    private lazy var rowContextMenu = ThreadRowContextMenu()
    /// The order the engaged toolbar last chose; day grouping follows Recent
    /// only — a Trending rank has no chronology to pin days over.
    private var commentSortOrder: SnapCommentSortButton.Order = .recent
    /// Builds the composer avatar's profile switcher menu. Nil wherever the
    /// app wires none — the face is then a plain, inert identity.
    private let profileSwitcher: (any ProfileSwitcherPresenting)?
    /// Watches for profile switches made ANYWHERE — this composer's menu, or
    /// the profile header while the comments sit open underneath.
    private let activeProfileObservers = NotificationObserverTokenBag()

    /// The stream surface: a compositional-list collection view driven by
    /// a diffable data source — thread folds and sort re-ranks land as
    /// NATIVE animated snapshot applies (insertions, deletions, moves),
    /// never manual view surgery. Still a UIScrollView underneath, so the
    /// engaged inset/keyboard machinery operates on it unchanged.
    private lazy var collectionView: UICollectionView = {
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
    private var hasAppliedStream = false
    /// True for the one apply that replaces the skeleton rows with the
    /// loaded comments: those cells fade in, staggered, instead of popping.
    /// A post whose comments were cached never shows bones and never sets
    /// this, so its rows are there at once (charter P7, P10).
    private var revealsLoadedRows = false
    /// Views staged for the reveal, played once the apply is over — see
    /// `playStagedReveal`.
    private var stagedReveals: [UIView] = []
    private var commentsLoaded = false
    /// The first page of comments failed with nothing to show (#798): the
    /// empty row says so, with a Try Again, instead of "No comments yet".
    private var commentsFailed = false
    /// What the failed row says: the view model's words, "You're offline"
    /// when that is why (#794).
    private var commentsFailureText = PostDetailViewModel.commentsFailureMessage
    private var streamModels: [String: CommentDisplayModel] = [:]
    /// A failed first load, with its way out (#797).
    private let statusView = EmptyStateView()

    private let composeBar = CommentsInputBar()

    private var composeBottomDefault: NSLayoutConstraint?
    private var composeBottomEngaged: [NSLayoutConstraint] = []
    /// **The action column (`SnapActionColumn`).** The engaged composer
    /// stands its stake and rail slot ON the media layout's like and repost
    /// bubbles — same size, same screen coordinates — so opening and closing
    /// the comments crossfades two bubbles that never move. The slot wears
    /// the post's sound (`publishedRailFace`); the waveform and the send
    /// arrow are in the field.
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
    /// The threaded stream as last loaded — kept so expansion re-renders
    /// without a refetch.
    private var latestComments: [CommentDisplayModel] = []
    /// The post as last rendered — the caption row's model, kept so a
    /// snapshot re-apply can rebuild item #0 without a refetch.
    private var latestPost: PostDetailDisplayModel?
    /// The caption the opener already had, used until this screen's own post
    /// load returns.
    ///
    /// The caption row is the stream's first item and it existed only once the
    /// POST had loaded — which is a network round trip after the panel mounts.
    /// For a hero flight that is far too late: the row the card is supposed to
    /// land its caption ON did not exist while the card was in the air, so the
    /// flight had no target and the caption appeared as a second one when the
    /// post arrived.
    private var seededCaption: (text: String, timestamp: String)?
    /// The caption row's face and metric line, from the surface that opened
    /// this page. Survives hydration: a `FeedEntry` knows the format but not
    /// the view or comment counts, so the seed stays the source for the line
    /// (see `CaptionBubbleCell.configure`).
    private var seededCardMetrics: PostCardMetrics?
    /// The author the opener handed over, so a seeded row wears its NAME and
    /// its avatar from frame one rather than an empty disc and a blank header
    /// until the fetch lands. The row names its author now (it is shaped like a
    /// comment), so the name is as load-bearing as the picture.
    private var seededAuthor: (name: String, monogram: String, avatarURL: URL?)?
    /// Parents whose full reply pool is shown (the "view more" seam's
    /// state). Per-screen, like scroll position.
    private var expandedReplyParents: Set<String> = []
    /// The armed reply target: the THREAD PARENT's id (replying to a reply
    /// binds to its top-level parent — comment.v1's two-depth contract)
    /// plus the tapped author's name for the placeholder.
    private var replyTarget: (parentID: String, name: String)?
    /// The viewer's point balance, spent by the compose bar's boost button.
    /// Injected (one instance app-wide — the map's badge watches it); nil
    /// leaves the button visible but inert.
    private let wallet: WalletStore?
    /// Keeps the compose bar's receipt honest when the SAME post is boosted
    /// through another surface (a text page shows this bar and the snap
    /// screen's spend path at once). Token bag, not deinit — the house
    /// escape hatch for main-actor state a nonisolated deinit can't touch.
    private let walletObservers = NotificationObserverTokenBag()
    /// The session's undoable spend through THIS bar. Its window is this
    /// controller's lifetime, which IS the product rule: the embedded
    /// comments panel is torn down when the page changes, so moving on
    /// finalizes the spend.
    private var sessionBoostAmount = 0
    /// The stake toast up for that spend (#957), closed with the window.
    private weak var stakeToast: ToastView?

    init(
        viewModel: PostDetailViewModel,
        imagePipeline: ImagePipeline,
        profileSwitcher: (any ProfileSwitcherPresenting)? = nil,
        wallet: WalletStore? = nil,
        threadChrome: Bool = false,
        groupsByDay: Bool = false
    ) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.threadChrome = threadChrome
        self.groupsByDay = threadChrome || groupsByDay
        self.profileSwitcher = profileSwitcher
        self.wallet = wallet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Takes back everything this bar spent while the screen stayed up — the
    /// menu's Undo entry and the stake toast's (#957).
    private func undoSessionBoost() {
        guard let wallet, sessionBoostAmount > 0, let postID = viewModel.postID,
              let result = wallet.undoBoost(targetID: postID.rawValue, amount: sessionBoostAmount)
        else { return }
        let refunded = sessionBoostAmount
        sessionBoostAmount = 0
        // Taken back: the toast closing must not send it.
        _ = stakeBurst.next()
        HapticImpact(style: .light).impactOccurred()
        composeBar.setBoostTotal(result.targetTotal, animated: true)
        composeBar.playBoostRefund(amount: refunded)
        refreshComposeBarBoostState()
        StakeMenu.closeUndoToast(stakeToast)
    }

    /// Leaving the post commits its likes now, rather than 10 s after the
    /// last tap (#676) — unless its stake toast is still up: the toast
    /// follows the screen on top, its Undo live, and sends the burst when
    /// it ends (#1375, the owner 2026-10-18).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let toastIsUp = stakeToast.map { !$0.isDismissing } ?? false
        if !toastIsUp, let postID = viewModel.postID { wallet?.commitStakes(on: postID.rawValue) }
    }

    /// Numbers this screen's stake toasts (`StakeMenu.Burst`).
    private let stakeBurst = StakeMenu.Burst()

    /// Rows re-measure on a genuine WIDTH change — rotation, iPad size
    /// classes. Nothing here touches the empty page's HEIGHT: that is
    /// resolved once at configuration time and deliberately never revisited
    /// per layout, because a height that changes after frame 0 is the jump.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        remeasureStreamOnWidthChange()
        refitEmptyPageOnHeightChange()
        syncDayUnderHeader()
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
        refitEmptyPage()
    }

    /// Re-fits a shown empty page to the current geometry and text size.
    ///
    /// Two things move its fit after it was decided: the room (a sheet's
    /// detent, above) and the block's own height, which is the page's floor
    /// and grows with the text size. `applyStream` reconfigures the page
    /// only if the fit really changed, so a call that finds nothing to do
    /// costs one measurement.
    private func refitEmptyPage() {
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
    private func remeasureStreamOnWidthChange() {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Comments"
        view.backgroundColor = .systemBackground
        configureViews()
        // The snap feed's comments panel stands its stake bubble on the media
        // layout's like button: the same heart, badge and menu (#668).
        composeBar.usesLikeFace = true
        pushComposerLikeCount()
        if viewModel.isDraft { configureDraft() }

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onEngagementChange = { [weak self] state in self?.renderEngagement(state) }
        viewModel.onCommentsChange = { [weak self] state in self?.renderComments(state) }
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
        viewModel.onCommentPosted = { [weak self] id in self?.arrivingCommentID = id }
        viewModel.onReviewFailed = { [weak self] approve in
            let notice = Self.reviewFailureNotice(approve: approve)
            self?.presentNotice(notice.title, notice.message)
        }
        configureProfileSwitcher()
        // The empty page's floor is its block's own height, which the text
        // size changes — see `refitEmptyPage`.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: PostDetailViewController, _: UITraitCollection) in
            controller.refitEmptyPage()
        }
        // …and the keyboard takes the room the page is fitted to.
        observeKeyboardForEmptyPage()
        render(.loading)
        viewModel.viewDidLoad()
    }

    /// Arms the composer avatar's profile switcher.
    ///
    /// Two independent halves, and the observer is the one that matters:
    ///
    ///  • The MENU is built from the switcher's pre-formatted rows, which
    ///    need one async `reload()` first. `makeMenu` is then synchronous, so
    ///    the menu opens fully rendered on its first frame.
    ///  • The OBSERVER adopts whatever profile becomes active, whether the
    ///    switch came from this menu or from the profile header with the
    ///    comments still open. Listening to the broadcast rather than to the
    ///    menu's own callback is what keeps the composer's face and the
    ///    identity that posts the comment from drifting apart.
    private func configureProfileSwitcher() {
        activeProfileObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: .activeProfileDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                guard let id = ActiveProfileChange.profileID(from: notification) else { return }
                MainActor.assumeIsolated { self?.viewModel.adoptActiveViewer(id) }
            },
            // Someone else is here now — most often a guest who just signed
            // up from this composer's button: the face and the name re-read,
            // and so does the menu of profiles to switch between.
            NotificationCenter.default.addObserver(
                forName: .viewerDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.viewModel.reloadViewerIdentity()
                    self?.refreshProfileMenu()
                }
            },
        ]

        guard let profileSwitcher else { return }
        Task { [weak self] in
            await profileSwitcher.reload()
            guard let self else { return }
            composeBar.setProfileMenu(profileSwitcher.makeMenu(
                // Adding a profile is the Profile feature's flow and this
                // composer has no route to it, so the row is omitted rather
                // than shown inert.
                includesAddProfile: false,
                // The switch itself lands through the notification above;
                // rebuilding here only re-marks which row is active, so the
                // menu is correct the NEXT time it opens.
                onSwitch: { [weak self] in self?.refreshProfileMenu() },
                onAddProfile: {}
            ))
        }
    }

    private func refreshProfileMenu() {
        guard let profileSwitcher else { return }
        Task { [weak self] in
            await profileSwitcher.reload()
            guard let self else { return }
            composeBar.setProfileMenu(profileSwitcher.makeMenu(
                includesAddProfile: false,
                onSwitch: { [weak self] in self?.refreshProfileMenu() },
                onAddProfile: {}
            ))
        }
    }

    @objc private func handleStreamTap() {
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
    private func retireKeyboardOr(_ work: () -> Void) {
        if composeBar.isEditingDraft {
            view.endEditing(true)
        } else {
            work()
        }
    }

    // MARK: - Setup

    private func configureViews() {
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
        let keyboardDismissTap = UITapGestureRecognizer(target: self, action: #selector(handleStreamTap))
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
        configureComposeBar()
        // Scroll view fills above the compose bar. The default bottom stops
        // at the bar's top at rest, and at its input row's top while the
        // keyboard lifts the row above the bar (the bar itself never moves):
        // the higher of the two, pulled down to the bar by a low-priority
        // reach. The engaged context swaps all three for a full-bleed bottom
        // so the stream glides BEHIND the footer.
        let reach = collectionView.bottomAnchor.constraint(equalTo: composeBar.topAnchor)
        reach.priority = .defaultLow
        scrollBottomDefault = [
            collectionView.bottomAnchor.constraint(lessThanOrEqualTo: composeBar.topAnchor),
            collectionView.bottomAnchor.constraint(lessThanOrEqualTo: composeBar.inputRowTopAnchor),
            reach,
        ]
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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

    /// Pushes the wallet's current answer — affordability and the session
    /// tally — into the bar's boost button: the enable state and the menu
    /// it will build on its next long-press both derive from it.
    private func refreshComposeBarBoostState() {
        guard let wallet else { return }
        composeBar.setBoostContext(
            balance: wallet.stakeableBalance, undoableAmount: sessionBoostAmount, stakeShots: wallet.stakeShots
        )
    }

    /// The boost button's opening face: this viewer's spend on this post so
    /// far, from the wallet's ledger — nothing on a draft, which is not a post.
    private func refreshBoostTotal() {
        guard let wallet else { return }
        composeBar.setBoostTotal(viewModel.postID.map { wallet.boostTotal(forTarget: $0.rawValue) } ?? 0)
        refreshComposeBarBoostState()
    }

    // MARK: - Draft (the "+" menu's Text Post)

    /// Where a published draft is handed on: the Text Post page, which keeps
    /// this panel and changes its own bars from "writing" to "the post".
    var onPostPublished: ((FeedEntry) -> Void)?

    /// How many comments the stream holds — what the sort control waits on
    /// (`CommentSortPolicy`). Reported on every change.
    private(set) var commentCount = 0
    var onCommentCountChange: ((Int) -> Void)?

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

    /// Whether the composer holds unsent text: what closing the page would lose.
    var composerHasDraft: Bool {
        !composeBar.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A draft whose first message is on its way — already sent, past recall.
    var isPublishing: Bool { viewModel.isDraft && composeBar.isSending }

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
        composerBackdrop.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        composeBar.defaultPlaceholder = "Write your post…"
        composeBar.sendAccessibilityLabel = "Publish post"
    }

    /// The draft is a post now: the composer goes back to being a post's —
    /// "Comment as …", a send that comments, the boost in the slot the
    /// visibility held (a published post's audience is settled), and the
    /// post's sound in the rail slot.
    private func becomePublished(_ entry: FeedEntry) {
        composeBar.defaultPlaceholder = nil
        composeBar.sendAccessibilityLabel = nil
        composeBar.visibilityMenu = nil
        composeBar.railFace = publishedRailFace
        refreshBoostTotal()
        onPostPublished?(entry)
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

    /// A held comment's review that didn't go: it is still held.
    static func reviewFailureNotice(approve: Bool) -> (title: String, message: String) {
        (
            approve ? "Couldn't Approve Comment" : "Couldn't Decline Comment",
            "The comment is still held for your review. Try again in a moment."
        )
    }

    static func commentFailureNotice(refused: Bool) -> (title: String, message: String) {
        refused
            ? ("Comments Are Limited", "The author only takes comments from some people.")
            : ("Couldn't Comment", "Your comment wasn't sent. Your text is still here, so you can try again.")
    }

    /// The text page family's notices are alerts — see the conversation's.
    private func presentNotice(_ title: String, _ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func configureComposeBar() {
        // A post's rail slot wears its sound (`publishedRailFace`). A draft
        // is not a post: its slot stays empty until it is.
        composeBar.railFace = viewModel.isDraft ? .empty : publishedRailFace
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
        // The bar's boost button: wallet verdict here, theatre back on the
        // bar — the snap rail's exact contract, on the comments surface.
        // Debit-first, so the animation never promises a state the balance
        // doesn't have. Nil wallet (an unwired host) leaves the tap inert.
        composeBar.onBoost = { [weak self] spend in
            guard let self else { return }
            // A guest signs up first; the boost then lands as asked.
            MemberGates.perform(.like, from: self) { [weak self] in
                // A sign-up that finished after the post went unavailable
                // (#1404) has nothing left to boost.
                guard let self, self.showsPostActions, let wallet = self.wallet else { return }
                // A DRAFT is not a post yet, and a boost has nothing to land on —
                // said, rather than spent against an id that does not exist.
                guard let postID = self.viewModel.postID else {
                    return self.presentNotice("Boost", "You can boost your post once it's published.")
                }
                switch wallet.stake(spend, on: postID.rawValue) {
                case .boosted(_, let targetTotal, let spent):
                    // `spent`, never the request — a near-cap boost is clamped.
                    self.sessionBoostAmount += spent
                    HapticImpact(style: .medium).impactOccurred()
                    // Receipt before theatre — the button flips to (or grows)
                    // its number face, then the "+N" float rises off it.
                    self.composeBar.setBoostTotal(targetTotal, animated: true)
                    self.composeBar.playBoostConfirmation(amount: spent)
                    // The burst so far, with Undo for all of it (#957) — until
                    // the toast ends, wherever it has followed to (#1375).
                    let burst = self.stakeBurst
                    let generation = burst.next()
                    let amount = self.sessionBoostAmount
                    let key = postID.rawValue
                    self.stakeToast = StakeMenu.undoToast(
                        staked: amount, on: key, from: self,
                        above: self.composeBar.inputRowView,
                        commit: { [weak self] in
                            guard burst.isCurrent(generation) else { return }
                            wallet.commitStakes(on: key)
                            self?.sessionBoostAmount = 0
                        },
                        undo: { [weak self] in
                            if let self {
                                self.undoSessionBoost()
                            } else {
                                _ = wallet.undoBoost(targetID: key, amount: amount)
                            }
                        }
                    )
                case .insufficientBalance, .targetCapReached, .noShotsLeft, .shotDoesNotFit:
                    HapticNotification().notificationOccurred(.error)
                    self.composeBar.playBoostDenied()
                }
                self.refreshComposeBarBoostState()
            }
        }
        // The menu's Undo entry: takes back everything this bar spent while
        // the screen stayed up. Session-scoped by construction — the tally
        // lives on this controller, and this controller dies with the visit.
        composeBar.onBoostUndo = { [weak self] in self?.undoSessionBoost() }
        // The button's opening face: this viewer's spend so far on this
        // post, from the wallet's ledger — a boosted post greets its
        // booster with the receipt, not the invitation. The observer keeps
        // it honest against spends made through any other surface.
        if let wallet {
            refreshBoostTotal()
            walletObservers.tokens = [
                NotificationCenter.default.addObserver(
                    forName: WalletStore.didChangeNotification, object: wallet, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshBoostTotal() }
                },
            ]
        }
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

    /// Shapes the scrolling content for the snap feed's engaged layout:
    /// `top` is the frosted media strip's height — the scroll view itself
    /// spans the full cell (comments glide UNDER the strip), so the content
    /// rests below it via inset, not via frame; `trailing` reserves the
    /// action rail's exclusive column (zero overlap). The composer
    /// deliberately stays full-width: the rail's territory ends well above
    /// the footer.

    /// Wires the INTERACTIVE pull-down dismissal: dragging the list down
    /// from its top drives the collapse under the finger. The list forwards
    /// each phase with the raw downward translation and release velocity;
    /// the host renders the progress and decides, on release, whether to
    /// finish or spring back. Left unwired by text posts (whose engagement
    /// is permanent) — nil makes the gesture a plain scroll.
    func setPullDismissDriveHandler(
        _ handler: @escaping (CommentsInputBar.PageSwipePhase, _ translation: CGFloat, _ velocity: CGFloat) -> Void
    ) {
        onPullDismissDrive = handler
    }
    private var onPullDismissDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)?

    /// Closes a menu the host has on show over this list (the comments' sort
    /// menu) and answers whether there was one (#759).
    var closesMenuOnShow: (() -> Bool)?
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

    /// Wires the composer's INTERACTIVE page-swipe — the bar forwards each
    /// pan phase (began/changed/ended) with the raw vertical translation and
    /// velocity, and the host drives the feed pager's `contentOffset` in
    /// real time (finger-linked paging), settling on release.
    func setEngagedPageSwipeHandler(
        _ handler: @escaping (CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void
    ) {
        composeBar.onPageSwipe = handler
    }

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
        collectionView.transform = CGAffineTransform(scaleX: scale, y: scale)
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

    /// The stream's two moving parts, driven by Core Animation directly
    /// rather than inside a `UIView.animate` block. Symmetric: the exit runs
    /// the same three animations towards the offstage pose.
    ///
    /// Model values are set FIRST and unanimated (so the settled state is
    /// correct even if the animation is removed), then one explicit
    /// animation per property carries the eye from where it actually was.
    /// `presentation()` rather than the model value as the start, so an
    /// interrupted entrance continues from what is on screen instead of
    /// snapping back.
    func animateEngagedTransition(toEngaged engaged: Bool, duration: TimeInterval) {
        let stream = collectionView.layer
        let bar = composeBar.layer
        let fromStream = (stream.presentation() ?? stream).transform
        let fromBarOpacity = (bar.presentation() ?? bar).opacity
        let fromBarTransform = (bar.presentation() ?? bar).transform

        UIView.performWithoutAnimation {
            setStreamTransitionProgress(engaged ? 0 : 1)
            setComposerEntranceState(offstage: !engaged)
        }

        addEntranceAnimation(stream, "transform", from: fromStream, to: stream.transform, duration: duration)
        addEntranceAnimation(bar, "opacity", from: fromBarOpacity, to: bar.opacity, duration: duration)
        addEntranceAnimation(bar, "transform", from: fromBarTransform, to: bar.transform, duration: duration)
    }

    private func addEntranceAnimation(
        _ layer: CALayer, _ keyPath: String, from: Any, to: Any, duration: TimeInterval
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "comments-engage-\(keyPath)")
    }

    /// Materializes the footer band's blur AHEAD of the engagement — the
    /// composer's half of `SnapFeedCell.prematerializeEngagedChrome`, and the
    /// same reasoning: build the material while nothing is moving.
    ///
    /// Called after the offstage pose, which nils the effect; the entrance
    /// then finds it already built and skips.
    func prematerializeComposerChrome() {
        guard view.window != nil, !composerBackdrop.isHidden,
              composerBackdrop.effect == nil else { return }
        composerBackdrop.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
    }

    /// Extra bottom room so resting content clears the composer: the bar's
    /// resting top above the footer line (its rest gap and its height, the
    /// lifted column and the stake on it included), plus the breath a resting
    /// row keeps above it — the column's two bubbles sit at the trailing
    /// edge, where a resting row's ♥ would be.
    private var engagedFooterClearance: CGFloat {
        composerRestingGap
            + CommentsInputBar.restingHeight(for: .large, postActions: composeBar.showsPostActions)
            + Self.composerTopBreath
    }

    /// Between the resting composer's top and the content resting above it.
    private static let composerTopBreath: CGFloat = 16

    /// The composer's resting gap above the footer line: its input row
    /// `glassGap` above the toolbar's glass — the bar lifts its own column
    /// (`SnapActionColumn`).
    private var composerRestingGap: CGFloat { SnapActionColumn.inputRestingGap + composerLift }

    /// (#1716, #1722): the composer rises with the page's bottom block — one
    /// breath over the bar — so the action column keeps its place.
    private var composerLift: CGFloat = SnapActionColumn.bottomBreath

    func setComposerLift(_ lift: CGFloat) {
        guard lift != composerLift else { return }
        // A rest line already drawn moves by the difference.
        composeBottomEngaged.first?.constant -= lift - composerLift
        composerLift = lift
    }

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

    func setEngagedInsets(top: CGFloat, bottomInset: CGFloat) {
        // The strip inset is the ONLY top authority in the engaged context:
        // the full-cell scroll view would otherwise also inherit the safe
        // area's automatic adjustment and double-inset the resting position.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset.top = max(0, top)
        collectionView.verticalScrollIndicatorInsets.top = max(0, top)
        collectionView.contentOffset = CGPoint(x: 0, y: -max(0, top))
        // A clean minimal stream: no indicator (engaged context only).
        collectionView.showsVerticalScrollIndicator = false
        // TOTAL immersion: the stream spans the full height and glides
        // BEHIND the footer too — the scroll's bottom swaps from the
        // compose bar's top to the view's bottom, with a bottom inset so
        // resting content still clears the footer band. The frost keeps
        // the bar legible over the moving rows.
        NSLayoutConstraint.deactivate(scrollBottomDefault)
        if scrollBottomEngaged == nil {
            scrollBottomEngaged = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }
        scrollBottomEngaged?.isActive = true
        collectionView.contentInset.bottom = max(0, bottomInset) + engagedFooterClearance
        // Recorded so the empty page can be sized against the SETTLED
        // geometry on frame 0 — the stream is still growing into these
        // numbers while the transition runs.
        engagedStreamInsets = (
            top: max(0, top),
            bottom: max(0, bottomInset) + engagedFooterClearance
        )
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

    private var composerTracksKeyboard = true

    // MARK: - Render

    private func render(_ phase: PostDetailViewModel.Phase) {
        switch phase {
        case .loading:
            statusView.isHidden = true
            // The skeleton stream IS the loading state (the messages
            // doctrine) — no spinner, no hidden surface.
            collectionView.isHidden = false
            if !hasAppliedStream { applyStream(animated: false) }
        case .content(let model):
            statusView.isHidden = true
            collectionView.isHidden = false
            setPostActionsShown(true)
            configure(model)
        case .failed(let message):
            collectionView.isHidden = true
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
            collectionView.isHidden = true
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
    private var showsPostActions = true

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
        // The footer band's veil, from the post's own format — the model
        // already knows, so this needs no signal from the host.
        composerBackdrop.setVeilOpacity(
            SnapCommentsLayout.frostVeilOpacity(hasMedia: model.hasMedia)
        )
        if model.hasCaption != hadCaption || hasAppliedStream {
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
            applyStream(animated: Self.animatesStreamApply(
                hasAppliedStream: hasAppliedStream,
                introducesCaption: model.hasCaption && !hadCaption
            ))
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
    private var captionLikeCount: Int64? { liveLikeCount ?? seededCardMetrics?.reactions }

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
        guard captionLikeCount != before, streamDataSource != nil else { return }
        var snapshot = streamDataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.caption) else { return }
        snapshot.reconfigureItems([.caption])
        streamDataSource.apply(snapshot, animatingDifferences: false)
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
    func seedCaption(
        _ text: String,
        timestamp: String,
        authorName: String = "",
        monogram: String = "",
        avatarURL: URL? = nil,
        metrics: PostCardMetrics? = nil
    ) {
        guard !text.isEmpty, latestPost == nil else { return }
        seededCaption = (text, timestamp)
        seededAuthor = (authorName, monogram, avatarURL)
        seededCardMetrics = metrics
        loadViewIfNeeded()
        pushComposerLikeCount()
        applyStream(animated: false)
    }

    /// The post this panel is about — nil on a draft.
    var postID: PostID? { viewModel.postID }

    /// What a published post's rail slot wears: the sound's cover the snap
    /// feed hands over (`setRailSoundFace`, #671) — nothing for a post with
    /// no sound bubble.
    private var publishedRailFace: CommentsInputBar.RailFace {
        railSoundFace.map { .sound($0) } ?? .empty
    }

    private var railSoundFace: SnapSoundFace?

    /// The snap feed's sound bubble face, for the rail slot that stands on it
    /// (#671).
    func setRailSoundFace(_ face: SnapSoundFace?) {
        railSoundFace = face
        guard !viewModel.isDraft else { return }
        composeBar.railFace = publishedRailFace
    }

    /// The rail slot's sound gestures (#680) — the snap feed's: a tap toggles
    /// the sound, a hold opens the sound sheet, as the media page's sound
    /// bubble does. A text post's page has no bubble of its own: this slot is
    /// its sound control.
    /// Redraws the rail slot's cover once a fetched one has landed (#680).
    func redrawRailSoundFace() {
        composeBar.redrawRailFace()
    }

    /// The post turned out unavailable to the viewer (#447) — said once, as
    /// this panel takes its own actions away (#1404). For a host that draws
    /// post actions outside the panel: the snap page (#1409).
    var onPostUnavailable: ((PostID) -> Void)?

    /// (#1681, the For You root): save and repost upright in
    /// the composer's column — drawn on a text page, reserved under a media
    /// page's (which draws its own) — the star for `saved`.
    func setPostActions(shown: Bool, saved: Bool, onSave: (() -> Void)?, onShare: (() -> Void)? = nil) {
        composeBar.showsPostActions = shown
        composeBar.postActions.setSaved(saved)
        composeBar.postActions.onSave = onSave
        composeBar.postActions.onShare = onShare
    }

    /// The composer's star after a save anywhere (#1681).
    func setPostSaved(_ saved: Bool) {
        composeBar.postActions.setSaved(saved)
    }

    /// The snap feed's page draws the action column above this panel (#695):
    /// the composer only reserves its room.
    func setActionColumnHostedByPage(_ hosted: Bool) {
        composeBar.hostsActionColumn = !hosted
    }

    /// The slot's cover turns while the post plays aloud (#692).
    func setRailSoundSpinning(_ spinning: Bool) {
        composeBar.setRailSpinning(spinning)
    }

    func setRailSoundActions(tap: (() -> Void)?, hold: (() -> Void)?) {
        composeBar.onRailAction = tap
        composeBar.onRailLongPress = hold
    }

    /// The stake bubble's like badge reads the caption row's count — one
    /// number on one panel.
    private func pushComposerLikeCount() {
        composeBar.setLikeCount(captionLikeCount)
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

    private func renderComments(_ state: PostDetailViewModel.CommentsState) {
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
        if models.count != commentCount {
            commentCount = models.count
            onCommentCountChange?(models.count)
        }
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

    // MARK: - Landing the viewer's comment (#921)

    /// The longest a landing waits for its scroll to say it ended: UIKit's
    /// animated scroll takes about 0.3 s, and it says nothing when a drag
    /// interrupts it.
    static let landingScrollTimeout: TimeInterval = 0.6
    /// The room a landing slot needs on screen to count as visible: about one
    /// short comment row.
    static let landingRowAllowance: CGFloat = 72

    /// A posted comment whose stream is waiting for the list to get there.
    private var pendingLanding: (id: String, reconfiguring: [StreamItem], target: CGPoint)?
    /// Bumped by every landing, so a scroll that was overtaken lands nothing.
    private var landingGeneration = 0

    /// The viewer's comment lands WHERE THEY CAN SEE IT (#921): the list first
    /// goes to its slot, then the comment arrives there with its effect — it
    /// is never inserted off screen. A slot already on screen skips the scroll.
    private func landPostedComment(_ id: String, reconfiguring: [StreamItem]) {
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
        collectionView.setContentOffset(target, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingScrollTimeout) { [weak self] in
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
        if slotY >= visibleTop - 0.5, slotY + Self.landingRowAllowance <= visibleBottom { return nil }
        let minY = -insets.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        let wanted = slotY - insets.top - (visibleBottom - visibleTop) / 3
        let y = min(max(wanted, minY), maxY)
        guard abs(y - offset) > 0.5 else { return nil }
        return CGPoint(x: collectionView.contentOffset.x, y: y)
    }

    /// The viewer's comment that just landed, until its row has arrived.
    private var arrivingCommentID: String?

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
              let row = Self.commentRow(in: cell) else { return }
        row.playAppear(in: cell.contentView)
        #if DEBUG
        debugPlayedArrivals.append(id)
        debugLandingEvents.append("arrive:\(id)")
        #endif
    }

    /// The comment row a stream cell carries, whichever cell it is.
    static func commentRow(in cell: UICollectionViewCell) -> CommentRowView? {
        (cell as? CommentCell)?.row ?? (cell as? ThreadRowCell)?.row
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
            UIView.animate(withDuration: Self.boneFade, delay: 0, options: [.curveEaseOut]) {
                ghost.alpha = 0
            } completion: { _ in
                ghost.removeFromSuperview()
            }
        }
    }

    // MARK: - Stream data source

    /// How long the bones take to step aside.
    static let boneFade: TimeInterval = 0.2
    /// The first row starts as the bones are half gone; each next one a beat
    /// later, up to `revealStaggerCap` rows — past that the tail arrives
    /// together rather than trickling in for a second.
    static let revealLead: TimeInterval = 0.08
    static let revealStagger: TimeInterval = 0.045
    static let revealStaggerCap = 8
    /// A rise of a few points and a hair of scale: the row settles INTO its
    /// place rather than appearing on it. Small on purpose — a list, not a
    /// stage entrance.
    static let revealRise: CGFloat = 10
    static let revealScale: CGFloat = 0.97

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
            target.transform = CGAffineTransform(translationX: 0, y: Self.revealRise)
                .scaledBy(x: Self.revealScale, y: Self.revealScale)
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
                delay: Self.revealLead + Self.revealStagger * Double(min(order, Self.revealStaggerCap)),
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
                action: fit.copy.actionTitle == nil ? nil : { [weak self] in self?.viewModel.retryComments() }
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
    /// Only under Recent, with comments loaded and some to show: a Trending
    /// rank, a skeleton and the empty page have no chronology to pin days over.
    private func streamSections() -> [(section: StreamSection, items: [StreamItem])] {
        let items = streamItems()
        guard groupsByDay, commentsLoaded, commentSortOrder == .recent, !latestComments.isEmpty else {
            return [(.main, items)]
        }
        let calendar = Calendar.current
        var sections: [(section: StreamSection, items: [StreamItem])] = [(.main, [])]
        var indexByDay: [Date: Int] = [:]
        var current = 0
        for item in items {
            if case .comment(let id) = item, let model = streamModels[id], model.isOwnThread {
                // The viewer's own threads (#921) ride with the caption, in
                // `.main`, above every day — they lead the stream, and a
                // day's pill must not gather everyone else's comments of
                // that day up under them.
                current = 0
            } else if case .comment(let id) = item, let model = streamModels[id], model.parentID == nil,
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
            self?.confirmCopied()
        }
        let select = UIAction(title: "Select Text", image: UIImage(systemName: "text.magnifyingglass")) {
            [weak self] _ in
            guard let self, let current = self.streamDataSource.indexPath(for: .comment(id)) else { return }
            self.rowContextMenu.beginTextSelection(at: current)
        }
        let share = UIAction(title: "Share Comment", image: AppSymbol.share.image()) {
            [weak self] _ in self?.presentCommentShare(model)
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
        if latestPost?.hasCaption == true || seededCaption != nil {
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
            let viewport = collectionView.bounds.height > 0
                ? collectionView.bounds.height
                : view.bounds.height
            let count = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: viewport)
            items.append(contentsOf: (0..<count).map(StreamItem.skeletonPlaceholder))
            return items
        }
        guard !latestComments.isEmpty else {
            items.append(.emptyState)
            return items
        }
        for item in CommentThreadPresentation.items(from: latestComments, expanded: expandedReplyParents) {
            switch item {
            case .comment(let model):
                items.append(.comment(model.id))
            case .viewMoreReplies(let parentID, let hiddenCount):
                items.append(.seam(.expand(hidden: hiddenCount), parentID: parentID))
            case .collapseReplies(let parentID):
                items.append(.seam(.collapse, parentID: parentID))
            }
        }
        return items
    }

    /// Whether a stream apply may animate. A cold apply never does (nothing
    /// to animate from), and neither does the one that introduces the
    /// CAPTION row — see `configure` for why a faded-in glass bubble reads
    /// as a dark-mode flash. Pure, so the rule is testable on its own.
    static func animatesStreamApply(hasAppliedStream: Bool, introducesCaption: Bool) -> Bool {
        hasAppliedStream && !introducesCaption
    }

    private func applyStream(
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
        hasAppliedStream = true
        nearEndItems = Self.nearEndItems(of: snapshot.itemIdentifiers)
        streamDataSource.apply(snapshot, animatingDifferences: animated) { completion?() }
    }

    /// The stream's last few rows: one of them coming on screen asks for the
    /// next page of comments (#589), early enough that it usually lands
    /// before the viewer reaches the end.
    private var nearEndItems: Set<StreamItem> = []
    static let nearEndRowCount = 5

    private static func nearEndItems(of items: [StreamItem]) -> Set<StreamItem> {
        Set(items.filter {
            switch $0 {
            case .comment, .seam: return true
            default: return false
            }
        }.suffix(nearEndRowCount))
    }

    /// The empty stream's words: an invitation to write while this is a
    /// DRAFT, an invitation to comment once it is a post.
    struct EmptyPageCopy: Equatable {
        let symbol: String
        let title: String
        let subtitle: String
        /// The block's button — only the failed stream's Try Again (#798).
        var actionTitle: String?
    }

    static let commentsEmptyPageCopy = EmptyPageCopy(
        // The comments glyph, app-wide — a DM thread's empty page keeps the
        // two bubbles (`ConversationThreadViewController`): a conversation is
        // not a post's comments.
        symbol: PostActionSymbol.comments,
        title: SnapCommentEmptyStateView.promptText,
        subtitle: "Be the first to comment."
    )

    static let draftEmptyPageCopy = EmptyPageCopy(
        symbol: "square.and.pencil",
        title: "Start your post",
        subtitle: "Your first message becomes the post."
    )

    /// The first page of comments failed with nothing on screen (#798). The
    /// SAME row as the empty page — same fit, same place — in other words,
    /// because what the reader needs is the reason the stream is empty, and
    /// the way out of it.
    static func commentsFailedPageCopy(_ message: String) -> EmptyPageCopy {
        EmptyPageCopy(
            symbol: "exclamationmark.triangle",
            title: commentsFailureTitle(message),
            subtitle: "Check your connection and try again.",
            actionTitle: "Try Again"
        )
    }

    /// The failed page's headline (#794): offline and a timeout get their
    /// short forms, since the subtitle already says what to do and saying
    /// "try again" twice reads as a stutter; anything else is the view
    /// model's own words.
    static func commentsFailureTitle(_ message: String) -> String {
        switch message {
        case FailureCopy.offline: FailureCopy.offlineTitle
        case FailureCopy.timeout: FailureCopy.timeoutTitle
        default: message
        }
    }

    private var emptyPageCopy: EmptyPageCopy {
        if commentsFailed { return Self.commentsFailedPageCopy(commentsFailureText) }
        return viewModel.isDraft ? Self.draftEmptyPageCopy : Self.commentsEmptyPageCopy
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

    /// The engaged context's own insets, kept so the settled geometry can be
    /// computed before the transition has produced it. Nil until engaged.
    private var engagedStreamInsets: (top: CGFloat, bottom: CGFloat)?

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
        var composerTop = composerBottom - CommentsInputBar.restingHeight(
            for: category, postActions: composeBar.showsPostActions
        )
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

    /// How much of the screen's bottom the keyboard covers while it is up,
    /// nil when it is down.
    ///
    /// ⚠️ A HEIGHT, NEVER A CONVERTED POSITION. The sheet grows to its large
    /// height FOR the keyboard, so this view is moving while the keyboard is:
    /// converting the keyboard's frame into this view's coordinates answered
    /// 520 where the truth was 377 — measured — and the invitation then sat
    /// as though no keyboard were up. A height needs no coordinate space, and
    /// the composer's own ceiling is anchored to the screen the same way (see
    /// `setEngagedInsets`).
    ///
    /// Read from the notification's END frame rather than from
    /// `keyboardLayoutGuide`: the guide only reaches that value as the
    /// keyboard finishes animating, and the empty page is fitted once, to
    /// where things are going.
    private var keyboardHeightFromBottom: CGFloat?
    private let keyboardObservers = NotificationObserverTokenBag()

    private func observeKeyboardForEmptyPage() {
        let center = NotificationCenter.default
        keyboardObservers.tokens = [
            // The frame is read out here: a `Notification` cannot cross into
            // the main actor's isolation, and a `CGRect` can.
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardIsMoving(endingAt: frame) }
            },
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardIsMoving(endingAt: frame) }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWentDown() }
            },
        ]
    }

    private func keyboardIsMoving(endingAt frame: CGRect?) {
        guard let window = view.window, let frame else { return }
        let covered = max(0, window.screen.bounds.maxY - frame.minY)
        guard keyboardHeightFromBottom != covered else { return }
        keyboardHeightFromBottom = covered
        refitEmptyPage()
    }

    private func keyboardWentDown() {
        guard keyboardHeightFromBottom != nil else { return }
        keyboardHeightFromBottom = nil
        refitEmptyPage()
    }

    /// The empty stream's section insets, mirroring the layout
    /// (`collectionView`): no top inset — the stream leads with its caption
    /// row, even while a draft has none yet — and `Spacing.lg` at the bottom.
    private var streamSectionVerticalInsets: CGFloat { Spacing.lg }

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
        let composerHeight = CommentsInputBar.restingHeight(
            for: contentSizeCategory, postActions: composeBar.showsPostActions
        )
        let blockClearsComposer = rowTop + block + composerRestingGap + composerHeight + restingBottomInset
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

    // MARK: - The day under the header (#757)

    /// The day of the last chip gone under the stream's top edge — what the
    /// host's bar shows left of the points — or nil before one has, or with
    /// no days at all (Trending, a skeleton, an empty page).
    var onDayUnderHeaderChange: ((Date?) -> Void)?
    private(set) var dayUnderHeader: Date?

    private func syncDayUnderHeader() {
        var day = groupsByDay ? lastDayGoneUnderTheTop() : nil
        #if DEBUG
        if let debugDayUnderTheTop { day = debugDayUnderTheTop() }
        #endif
        guard day != dayUnderHeader else { return }
        dayUnderHeader = day
        onDayUnderHeaderChange?(day)
    }

    private func lastDayGoneUnderTheTop() -> Date? {
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
        #if DEBUG
        debugOnScrollToDay?(day)
        #endif
        guard let streamDataSource,
              let section = streamDataSource.snapshot().sectionIdentifiers.firstIndex(of: .day(day)),
              let chip = collectionView.layoutAttributesForSupplementaryElement(
                  ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: section)
              )?.frame
        else { return }
        let insets = collectionView.adjustedContentInset
        let maxOffset = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        let offset = min(max(chip.maxY - insets.top, -insets.top), maxOffset)
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: animated)
    }

    /// Re-reads the day under the top. Tests, and the host after a layout.
    func debugSyncDayUnderHeader() { syncDayUnderHeader() }

    /// The stream's days, in order, with the section each heads. Tests.
    var debugStreamDays: [(day: Date, section: Int)] {
        guard let streamDataSource else { return [] }
        return streamDataSource.snapshot().sectionIdentifiers.enumerated().compactMap { index, section in
            guard case .day(let day) = section else { return nil }
            return (day, index)
        }
    }

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

    /// The engaged toolbar's sort selector lands here — the view model
    /// re-ranks the data and the diffable apply animates the moves.
    func setCommentSortOrder(_ order: SnapCommentSortButton.Order) {
        // Recorded BEFORE the view model re-emits: the re-render that follows
        // decides from it whether days are pinned.
        commentSortOrder = order
        viewModel.setCommentSort(order == .trending ? .trending : .recent)
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
            self.retireKeyboardOr { self.enterReplyState(for: model) }
        }
        row.onShare = { [weak self] in self?.presentCommentShare(model) }
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
            MemberGates.perform(.comment, from: self) { [weak self] in
                self?.viewModel.likeComment(commentID: model.id)
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

    /// Row tapped: the composer arms its reply state — placeholder names
    /// the tapped author, the payload binds to the THREAD parent, and the
    /// keyboard rises into the field.
    private func enterReplyState(for model: CommentDisplayModel) {
        replyTarget = (parentID: model.parentID ?? model.id, name: model.authorName)
        composeBar.setReplyPlaceholder(name: model.authorName)
        composeBar.focusComposer()
    }

    private func clearReplyState() {
        replyTarget = nil
        composeBar.setReplyPlaceholder(name: nil)
    }

    /// A comment's Copy says so (#803) — over the composer, which rests where
    /// the toast would, as in a conversation. Internal for tests.
    func confirmCopied() {
        let floor = composeBar.superview != nil && !composeBar.isHidden ? composeBar.inputRowView : nil
        Feedback.success("Copied", symbol: "doc.on.doc.fill", from: self, above: floor)
    }

    private func presentCommentShare(_ model: CommentDisplayModel) {
        let sheet = UIActivityViewController(
            activityItems: ["\(model.authorName): \(model.body)"],
            applicationActivities: nil
        )
        present(sheet, animated: true)
    }

    private var didCascadeComments = false

    private func renderComposing(_ composing: Bool) {
        composeBar.isSending = composing
        onComposingChange?(composing)
    }

    /// Whether a send is in flight — for a host that must not let go of the
    /// screen meanwhile: the Text Post page, while its post is on its way.
    var onComposingChange: ((Bool) -> Void)?
}

// MARK: - Interactive pull-down dismissal

extension PostDetailViewController: UICollectionViewDelegate {
    /// Paging, not dismissal: one of the stream's last rows coming on screen
    /// asks for the next page of comments (#589).
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = streamDataSource.itemIdentifier(for: indexPath), nearEndItems.contains(item) else { return }
        viewModel.loadMoreComments()
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
        // ⚠️ A MENU ON SHOW TAKES THE GESTURE (#759): the drag closes it and
        // ends there — it neither scrolls nor arms the pull-down close, whose
        // animation fought the menu's own.
        if closesMenuOnShow?() == true {
            isPullDismissArmed = false
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
            return
        }
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
        isPullDismissArmed = Self.armsPullDismiss(
            atTop: scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5,
            keyboardOpen: composeBar.isKeyboardOpen
        )
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncDayUnderHeader()
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

    /// Whether a drag starting now may drive the pull-down close: from the
    /// list's top, with the keyboard down. Pure, for tests.
    static func armsPullDismiss(atTop: Bool, keyboardOpen: Bool) -> Bool {
        atTop && !keyboardOpen
    }

    /// How far past its resting top the list has been pulled, in points.
    /// Zero anywhere else — the resting offset is NEGATIVE here, since the
    /// engaged stream carries a top content inset.
    private func overshoot(of scrollView: UIScrollView) -> CGFloat {
        max(0, -(scrollView.contentOffset.y + scrollView.contentInset.top))
    }
}
