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

final class PostDetailViewController: UIViewController {
    /// Where an opened post is recorded — the profile's History tab
    /// (#1344): every post opened counts, here as in the vertical feed.
    var viewHistory: PostViewHistoryStore?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let postID = viewModel.postID { viewHistory?.record(postID.rawValue) }
    }

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
    /// The order the engaged toolbar last chose; day grouping follows Recent
    /// only — a Trending rank has no chronology to pin days over.
    var commentSortOrder: SnapCommentSortButton.Order = .recent
    /// Builds the composer avatar's profile switcher menu. Nil wherever the
    /// app wires none — the face is then a plain, inert identity.
    private let profileSwitcher: (any ProfileSwitcherPresenting)?
    /// Watches for profile switches made ANYWHERE — this composer's menu, or
    /// the profile header while the comments sit open underneath.
    private let activeProfileObservers = NotificationObserverTokenBag()

    /// The post's comments, as a list (`CommentStream`).
    private(set) lazy var stream = CommentStream(host: self)
    /// Every stream the panel holds.
    var streams: [CommentStream] { [stream] }
    /// What moves and hides as one: the streams.
    private var streamSurface: UIView { stream.collectionView }

    // MARK: - The stream, as the panel's

    // What a host asks of the panel's list (each documented on `CommentStream`).
    func setEmptyRoomTapHandler(_ handler: (() -> Void)?) { stream.setEmptyRoomTapHandler(handler) }
    func emptyRoomContains(_ location: CGPoint) -> Bool { stream.emptyRoomContains(location) }
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
        stream.scrollToDay(day, animated: animated)
    }
    var debugStreamDays: [(day: Date, section: Int)] { stream.debugStreamDays }
    #if DEBUG
    var debugPlayedArrivals: [String] { stream.debugPlayedArrivals }
    var debugLandingEvents: [String] { stream.debugLandingEvents }
    #endif

    /// A failed first load, with its way out (#797).
    private let statusView = EmptyStateView()

    let composeBar = CommentsInputBar()

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
        // Turning off is silent (#1881).
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
        streams.forEach { $0.remeasureStreamOnWidthChange() }
        refitEmptyPageOnHeightChange()
        syncDayUnderHeader()
        // Rows realised as the engaged stream grows into its room (#1799).
        streams.forEach { $0.syncBottomAnchor() }
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
        installRailWayBack()
        // The snap feed's comments panel stands its stake bubble on the media
        // layout's like button: the same heart, badge and menu (#668).
        composeBar.usesLikeFace = true
        pushComposerLikeCount()
        if viewModel.isDraft { configureDraft() }

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onEngagementChange = { [weak self] state in self?.renderEngagement(state) }
        viewModel.onCommentsChange = { [weak self] state in self?.stream.renderComments(state) }
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
        viewModel.onReviewFailed = { [weak self] approve in
            let notice = Self.reviewFailureNotice(approve: approve)
            self?.presentNotice(notice.title, notice.message)
        }
        configureProfileSwitcher()
        // The empty page's floor is its block's own height, which the text
        // size changes — see `refitEmptyPage`.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: PostDetailViewController, _: UITraitCollection) in
            controller.streams.forEach { $0.refitEmptyPage() }
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

        refreshProfileMenu()
    }

    /// Reloads the switcher's profiles and counts, and arms the avatar to
    /// open the app's one switcher (#2034) — switch-only: adding a profile is
    /// the Profile feature's flow and this composer has no route to it.
    private func refreshProfileMenu() {
        guard let profileSwitcher else { return }
        Task { [weak self] in
            await profileSwitcher.reload()
            guard let self else { return }
            composeBar.setProfileSwitch { [weak self] source in
                guard let self else { return }
                profileSwitcher.present(
                    from: .view(source), over: self, includesAddProfile: false,
                    // The switch itself lands through the notification above;
                    // the reload here re-marks the active row for next time.
                    onSwitch: { [weak self] in self?.refreshProfileMenu() },
                    onAddProfile: {}
                )
            }
        }
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
        stream.configure()
        configureComposeBar()
        // Scroll view fills above the compose bar. The default bottom stops
        // at the bar's top at rest, and at its input row's top while the
        // keyboard lifts the row above the bar (the bar itself never moves):
        // the higher of the two, pulled down to the bar by a low-priority
        // reach. The engaged context swaps all three for a full-bleed bottom
        // so the stream glides BEHIND the footer.
        let streamView = stream.collectionView
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

    /// The stream counted its comments: reported on a change.
    func noteCommentCount(_ count: Int) {
        guard count != commentCount else { return }
        commentCount = count
        onCommentCountChange?(count)
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
                    Haptics.play(.commit)
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
                    Haptics.play(.error)
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

    /// A tap at `location` in the stream's coordinates, through the
    /// recogniser's own decision, for tests.
    func debugTapStream(at location: CGPoint) {
        stream.debugTapStream(at: location)
    }

    /// The stream's frame of reference, for tests.
    var debugStream: UICollectionView { stream.collectionView }

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
    var onPullDismissDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)?

    /// Closes a menu the host has on show over this list (the comments' sort
    /// menu) and answers whether there was one (#759).
    var closesMenuOnShow: (() -> Bool)?

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
        let surface = streamSurface.layer
        let bar = composeBar.layer
        let fromStream = (surface.presentation() ?? surface).transform
        let fromBarOpacity = (bar.presentation() ?? bar).opacity
        // ⚠️ FROM THE MODEL unless an entrance is in flight (the owner's
        // video, 2026-10-25): the side list's offset (`setOverlayOffset`) is
        // set just before this, and the presentation layer still shows the
        // transform of the last commit — identity for a panel released at 0.
        // Read from there, the bar was drawn without the offset for the whole
        // engagement and jumped into place at its end.
        let fromBarTransform = bar.animation(forKey: "comments-engage-transform") != nil
            ? (bar.presentation() ?? bar).transform
            : bar.transform

        UIView.performWithoutAnimation {
            setStreamTransitionProgress(engaged ? 0 : 1)
            setComposerEntranceState(offstage: !engaged)
        }

        addEntranceAnimation(surface, "transform", from: fromStream, to: surface.transform, duration: duration)
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
        CommentsInputBar.restingHeight(
            for: category, showsStake: composeBar.showsStake, postActions: composeBar.showsPostActions
        )
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
    /// the default since #1923). Settable for tests, before
    /// the stream is engaged.
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
        metrics: PostCardMetrics? = nil
    ) {
        guard !text.isEmpty, latestPost == nil else { return }
        seededCaption = (text, timestamp)
        seededAuthor = (authorName, monogram, avatarURL)
        seededCardMetrics = metrics
        loadViewIfNeeded()
        pushComposerLikeCount()
        streams.forEach { $0.applyStream(animated: false) }
    }

    /// The post this panel is about — nil on a draft.
    var postID: PostID? { viewModel.postID }

    /// What a published post's rail slot wears: Share on a pushed text page
    /// (`setRailShare`, #1999), else the sound's cover the snap feed hands
    /// over (`setRailSoundFace`, #671) — nothing for a post with neither.
    private var publishedRailFace: CommentsInputBar.RailFace {
        guard railKeepsSlot else { return .noSlot }
        guard railShareAction != nil || railSoundFace != nil else { return .empty }
        // The way back (#1929), on a slot this composer draws; under a page's
        // column the page's own bubble wears it (`onScrollAwayChange`).
        if stream.showsScrollAwayReturn, composeBar.hostsActionColumn { return .returnTo(down: false) }
        if railShareAction != nil { return .share }
        return railSoundFace.map { .sound($0) } ?? .empty
    }

    // MARK: The way back (#1929)

    /// The way back came or went — for a host whose page draws the sound
    /// bubble above this composer (the snap feed's column).
    var onScrollAwayChange: ((Bool) -> Void)?
    /// Whether the way back shows now.
    var showsScrollAwayReturn: Bool { stream.showsScrollAwayReturn }
    /// The sound's tap action, the host's (`setRailSoundActions`).
    private var soundTapAction: (() -> Void)?
    /// The way back's hold on the composer's own slot.
    private var railSoundHold: HoldToArmPresenter?
    /// Whether the host asked the slot's record to turn, kept while the way
    /// back hides it (#692).
    private var railSpinning = false

    /// The composer's slot as the way back stands.
    func applyRailWayBack() {
        if !viewModel.isDraft { composeBar.railFace = publishedRailFace }
        let returns = composeBar.railFace == .returnTo(down: false)
        if !returns { composeBar.setRailSpinning(railSpinning) }
        // Over Share (#1999) the hold arms Share on a media page — the
        // slot's own action — and nothing on a text page.
        let armsSheet = returns && railShareAction == nil && soundTapAction != nil
            && railSoundFace?.isAvailable == true
        let armsShare = returns && railShareAction != nil && railShareHoldArms
        railSoundHold?.isEnabled = armsSheet || armsShare
        // What the slot stood for stays reachable with the chevron up:
        // VoiceOver's road — the sound, or Share.
        if armsSheet {
            composeBar.railHoldTarget.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Sound") { [weak self] _ in
                    self?.soundTapAction?()
                    return true
                },
            ]
        } else if returns, railShareAction != nil {
            composeBar.railHoldTarget.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Share") { [weak self] _ in
                    self?.railShareAction?()
                    return true
                },
            ]
        } else {
            composeBar.railHoldTarget.accessibilityCustomActions = nil
        }
    }

    private func installRailWayBack() {
        composeBar.onRailAction = { [weak self] in
            guard let self else { return }
            if composeBar.railFace == .returnTo(down: false) { return scrollToStart(animated: true) }
            if composeBar.railFace == .share {
                railShareAction?()
            } else {
                soundTapAction?()
            }
        }
        let hold = HoldToArmPresenter(view: composeBar.railHoldTarget) { [weak self] in
            guard let self else { return .picture(nil) }
            return railShareAction != nil ? .symbol(CommentsInputBar.shareRailSymbol) : .picture(composeBar.railCoverImage)
        }
        hold.onFire = { [weak self] in
            guard let self else { return }
            if let railShareAction { railShareAction() } else { soundTapAction?() }
        }
        hold.isEnabled = false
        railSoundHold = hold
    }

    private var railSoundFace: SnapSoundFace?
    /// False for a text post with nothing in its slot (#1790, #1999): the
    /// composer has no slot, its field widens into it.
    private var railKeepsSlot = true
    /// The post's Share, when the slot wears it (#1999): a pushed page.
    private var railShareAction: (() -> Void)?
    /// Whether the way back's hold arms Share (#1999): a media page's.
    private var railShareHoldArms = false

    /// Share in the slot (#1999), the toolbar's old action, on a pushed page:
    /// a text page's (a text post has no sound) and a media page's (its sound
    /// moves to the footer). `holdArms`: the way back's hold arms Share — a
    /// media page's. Nil gives the slot back to the sound.
    func setRailShare(_ action: (() -> Void)?, holdArms: Bool = false) {
        railShareAction = action
        railShareHoldArms = action != nil && holdArms
        if action != nil { railKeepsSlot = true }
        guard !viewModel.isDraft else { return }
        applyRailWayBack()
    }

    /// The snap feed's sound bubble face, for the rail slot that stands on it
    /// (#671); `keepsSlot` false takes the slot away (#1790).
    func setRailSoundFace(_ face: SnapSoundFace?, keepsSlot: Bool = true) {
        railSoundFace = face
        railKeepsSlot = keepsSlot
        guard !viewModel.isDraft else { return }
        composeBar.railFace = publishedRailFace
    }

    /// The rail slot's sound gestures (#680) — the snap feed's: a tap toggles
    /// the sound, a hold opens the sound sheet, as the media page's sound
    /// bubble does. A text post's page has no bubble of its own: this slot is
    /// its sound control.

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
    ///
    /// ⚠️ A MEDIA PAGE FOLDS ITS COLUMN (`foldsIntoSlot`). With the comments
    /// up, its like and its post's actions fold into the sound bubble
    /// (#1872): only the slot is left, on the input row's line. Reserving
    /// the stake and the actions there kept ~110 pt of nothing over the
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
    var debugRailSoundHold: HoldToArmPresenter? { railSoundHold }
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

    /// The slot's cover turns while the post plays aloud (#692).
    func setRailSoundSpinning(_ spinning: Bool) {
        railSpinning = spinning
        composeBar.setRailSpinning(spinning)
    }

    /// The slot's sound actions: `tap` is what the sound does (the sheet);
    /// while the way back shows, a tap goes back to the top and a hold arms
    /// `tap` (#1929).
    func setRailSoundActions(tap: (() -> Void)?, hold: (() -> Void)?) {
        soundTapAction = tap
        composeBar.onRailLongPress = hold
        applyRailWayBack()
    }

    /// The stake bubble's like badge reads the caption row's count — one
    /// number on one panel.
    private func pushComposerLikeCount() {
        composeBar.setLikeCount(captionLikeCount)
    }

    /// The first page's bones on the kit's timing (#1770). Injectable so a
    /// test steps it.
    var skeletonClock: LoadingClock = .system

    // MARK: - Landing the viewer's comment (#921)

    /// The longest a landing waits for its scroll to say it ended: UIKit's
    /// animated scroll takes about 0.3 s, and it says nothing when a drag
    /// interrupts it.
    static let landingScrollTimeout: TimeInterval = 0.6
    /// The room a landing slot needs on screen to count as visible: about one
    /// short comment row.
    static let landingRowAllowance: CGFloat = 72

    /// The comment row a stream cell carries, whichever cell it is.
    static func commentRow(in cell: UICollectionViewCell) -> CommentRowView? {
        (cell as? CommentCell)?.row ?? (cell as? ThreadRowCell)?.row
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

    /// Whether a stream apply may animate. A cold apply never does (nothing
    /// to animate from), and neither does the one that introduces the
    /// CAPTION row — see `configure` for why a faded-in glass bubble reads
    /// as a dark-mode flash. Pure, so the rule is testable on its own.
    static func animatesStreamApply(hasAppliedStream: Bool, introducesCaption: Bool) -> Bool {
        hasAppliedStream && !introducesCaption
    }

    static let nearEndRowCount = 5

    /// Whether a drag starting now may drive the pull-down close: from the
    /// list's top, with the keyboard down. Pure, for tests.
    static func armsPullDismiss(atTop: Bool, keyboardOpen: Bool) -> Bool {
        atTop && !keyboardOpen
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

    /// The first page past 10 s (#1770): the empty page's row, saying so,
    /// with Try Again.
    static let commentsTakingLongerPageCopy = EmptyPageCopy(
        symbol: TakingLongerCopy.symbol,
        title: TakingLongerCopy.title,
        subtitle: "The comments are still on their way.",
        actionTitle: TakingLongerCopy.action
    )

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

    /// The engaged context's own insets, kept so the settled geometry can be
    /// computed before the transition has produced it. Nil until engaged.
    var engagedStreamInsets: (top: CGFloat, bottom: CGFloat)?

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
    var keyboardHeightFromBottom: CGFloat?
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
        // A short stream rises with the composer's input row (#1799).
        streams.forEach {
            $0.refitEmptyPage()
            $0.syncBottomAnchor(animated: true)
        }
    }

    private func keyboardWentDown() {
        guard keyboardHeightFromBottom != nil else { return }
        keyboardHeightFromBottom = nil
        streams.forEach {
            $0.refitEmptyPage()
            $0.syncBottomAnchor(animated: true)
        }
    }

    /// The empty stream's section insets, mirroring the layout
    /// (`collectionView`): no top inset — the stream leads with its caption
    /// row, even while a draft has none yet — and `Spacing.lg` at the bottom.
    var streamSectionVerticalInsets: CGFloat { Spacing.lg }

    // MARK: - The day under the header (#757)

    /// The day of the last chip gone under the stream's top edge — what the
    /// host's bar shows left of the points — or nil before one has, or with
    /// no days at all (Trending, a skeleton, an empty page).
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

    /// The engaged toolbar's sort selector lands here — the view model
    /// re-ranks the data and the diffable apply animates the moves.
    func setCommentSortOrder(_ order: SnapCommentSortButton.Order) {
        // Recorded BEFORE the view model re-emits: the re-render that follows
        // decides from it whether days are pinned.
        commentSortOrder = order
        viewModel.setCommentSort(order == .trending ? .trending : .recent)
    }

    /// Row tapped: the composer arms its reply state — placeholder names
    /// the tapped author, the payload binds to the THREAD parent, and the
    /// keyboard rises into the field.
    func enterReplyState(for model: CommentDisplayModel) {
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

    func presentCommentShare(_ model: CommentDisplayModel) {
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
