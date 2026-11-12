import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import EntityStore
import FeedInterface
import MediaCore
import ThreadKit
import UIKit
import VoiceKit
import VoiceKitUI

/// A conversation, drawn as a text post's screen.
///
/// The pieces are the text page's own, not look-alikes: messages are
/// `CommentRowView`s (avatar, "Name · 14:32", body — the viewer's too), the
/// composer is `CommentsInputBar` resting where the text page rests it, the
/// footer frost is the same `ProgressiveFrostView` band, and the
/// footer is `SnapFooterToolbar` with the peer's pill where a post shows its
/// author. What a conversation leaves out is what only a post has: the stake
/// (there is nothing to like), and the footer's save and repost — the
/// conversation's pin and bell take their room (#2305). What a conversation adds is a chat's reading order: oldest at the
/// top, the newest at the bottom, day pills pinned over each day, and a list
/// that follows new messages and the keyboard.
///
/// Chat drives it through `ConversationThreadDriving`; nothing here knows what
/// a `ChatMessage` is.
final class ConversationThreadViewController: UIViewController {
    private enum Section: Hashable {
        /// Loading, failed or empty — no day to pin.
        case main
        case day(Date)
    }

    private enum Item: Hashable {
        case skeleton(Int)
        /// The day chip's bone over the skeleton rows (#1774).
        case skeletonDay
        case empty
        case message(String)
        /// A line about the conversation (#2214): "You created the group".
        case system(String)
    }

    /// Read by the layout's section provider, which must not reach back
    /// through the controller — it is not isolated to the main actor, and a
    /// provider holding the controller is a retain cycle waiting to be
    /// forgotten. Written before every apply.
    private final class HeaderPolicy: @unchecked Sendable {
        var daySections = false
    }

    private let driver: any ConversationThreadDriving
    private let mode: ConversationThreadMode
    private let prefill: String
    private let imagePipeline: ImagePipeline

    private let headerPolicy = HeaderPolicy()
    private lazy var collectionView: UICollectionView = ConversationCollectionView(
        frame: .zero, collectionViewLayout: makeLayout()
    )
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let contextMenu = ThreadRowContextMenu()
    /// The app's one composer (#2308), from the conversation's contract
    /// (`composerConfiguration`): a message's voice where the driver sends
    /// voice, the camera and the library as its attachments (#2305), no
    /// column. The row, the own bubble and the hold are every host's. The
    /// pin and the bell are the footer's, the way back to the newest message
    /// floats over the composer (`returnButton`).
    private let composeBar = CommentsInputBar()
    /// The leftward swipe's push of the peer's profile (#1525).
    private(set) var swipeArbiter: SwipeStageArbiter?

    /// The conversation's pin as the driver last reported it — nil while
    /// there is nothing to pin (a draft).
    private var isPinned: Bool?

    private func renderPinned(_ pinned: Bool?) {
        isPinned = pinned
        applyPinLook()
    }

    /// The conversation's pin: a bar item of its own, left of the bell and
    /// apart from it (the owner, 2026-11-07) — on the FOOTER since #2305,
    /// `[peer pill] … [pin] [bell] [⋯]`, each its own bubble. Disabled until
    /// the driver reports one: a draft has nothing to pin. The action
    /// carries no image (`BarItems.icon`'s note: an action's image is
    /// re-applied to its item when it fires).
    private lazy var pinItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: nil, image: UIImage(systemName: "pin"),
            primaryAction: UIAction { [weak self] _ in self?.togglePin() }
        )
        item.identifier = "conversation.pin"
        item.tintColor = .label
        return item
    }()

    private func togglePin() {
        guard isPinned != nil else { return }
        driver.togglePinned()
    }

    private func applyPinLook() {
        pinItem.image = UIImage(systemName: isPinned == true ? "pin.fill" : "pin")
        pinItem.isEnabled = isPinned != nil
        pinItem.accessibilityLabel = isPinned == true ? "Unpin conversation" : "Pin conversation"
    }

    /// Scrolled away from the newest message, the way back shows (#1929).
    private var scrollAway = ScrollAwayPolicy()

    /// The way back to the newest message: a glass bubble floating over the
    /// composer's trailing end (the owner, 2026-11-07, Telegram's) — the
    /// composer's end is its voice and send now.
    private let returnButton: UIButton = {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(
            systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Scroll to latest message"
        button.isHidden = true
        return button
    }()

    /// A voice take shows in the field's place: the way back gives the
    /// column to the lock rising over the held bubble.
    private var composerRecords = false

    private var returnShows: Bool { scrollAway.showsReturn && !composerRecords }
    /// What the way back was last told — not `isHidden`, which stays false
    /// through a fade out: shown again mid-fade, it stayed at alpha 0.
    private var returnShown = false

    /// The way back comes in springing up from smaller as it fades in, and
    /// fades going.
    private func renderReturn() {
        let shows = returnShows
        guard shows != returnShown else { return }
        returnShown = shows
        let size: CGAffineTransform = shows ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        guard view.window != nil, !MotionPreference.reducesMotion else {
            returnButton.isHidden = !shows
            returnButton.alpha = 1
            returnButton.transform = .identity
            return
        }
        if shows, returnButton.isHidden {
            returnButton.isHidden = false
            returnButton.alpha = 0
            returnButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        UIView.animate(
            springDuration: 0.35, bounce: shows ? 0.25 : 0, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.returnButton.alpha = shows ? 1 : 0
            self.returnButton.transform = size
        } completion: { _ in
            guard !self.returnShows else { return }
            self.returnButton.isHidden = true
            self.returnButton.alpha = 1
            self.returnButton.transform = .identity
        }
    }

    /// Feeds the way-back policy: the distance from the newest message.
    private func syncScrollAway(userScroll: Bool) {
        let insets = collectionView.adjustedContentInset
        let bottom = collectionView.contentSize.height + insets.bottom - collectionView.bounds.height
        let distance = max(0, bottom - collectionView.contentOffset.y)
        let viewport = collectionView.bounds.height - insets.top - insets.bottom
        let before = scrollAway.showsReturn
        scrollAway.update(distance: distance, viewport: viewport, isUserScroll: userScroll)
        if scrollAway.showsReturn != before { renderReturn() }
    }

    /// The way back's state, for tests.
    var debugShowsReturn: Bool { scrollAway.showsReturn }
    var debugRailFace: CommentsInputBar.RailFace { composeBar.railFace }
    var debugComposeBar: CommentsInputBar { composeBar }
    var debugPinItem: UIBarButtonItem { pinItem }
    var debugShowsReturnButton: Bool { !returnButton.isHidden }
    var debugReturnButtonAlpha: CGFloat { returnButton.alpha }
    /// A tap on the way back.
    func debugTapReturn() { returnButton.sendActions(for: .primaryActionTriggered) }
    /// A tap on the bar's pin, through its own action.
    func debugTapPin() { togglePin() }
    /// The stream moved to `offset` — by the reader, or not — as a scroll
    /// callback reports it.
    func debugScroll(to offset: CGFloat, userScroll: Bool) {
        collectionView.contentOffset.y = offset
        syncScrollAway(userScroll: userScroll)
    }
    /// The stream's offset at its newest message.
    var debugBottomOffset: CGFloat {
        let insets = collectionView.adjustedContentInset
        return collectionView.contentSize.height + insets.bottom - collectionView.bounds.height
    }
    var debugStreamOffset: CGFloat { collectionView.contentOffset.y }
    /// No band of its own at the top (asked 2026-10-02): the window's
    /// status-bar blur (`StatusBarBlurView`) is the only material up there,
    /// and the nav capsules are glass of their own. A header frost under that
    /// band was a blur over a blur.
    private let composerBackdrop = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.footerFrostMaskColors,
        maskLocations: SnapCommentsLayout.footerFrostMaskLocations
    )
    /// A failed first load, with its way out (#797).
    private let statusView = EmptyStateView()
    /// Under the bar while older history is on its way (#600): pinned to the
    /// screen rather than to the content, so it is where the reader is
    /// looking — at the top — whatever the scroll. Turns only while a page
    /// is out; an idle spinner redraws the screen every frame (#580).
    private let olderSpinner = AppLoaderView(size: .medium)
    private let peerPill = SnapAuthorIdentityView()
    /// The conversation's mute (#719): `bell`, or `bell.slash` once muted —
    /// on the footer between the pin and ⋯ since #2305 (the top bar's
    /// trailing corner before). Hidden while there is nothing to mute (a
    /// draft).
    ///
    /// ⚠️ ONE ITEM FOR BOTH STATES, ITS GLYPH REPLACED IN PLACE (#2143, the
    /// owner's device check). One item per state (#729) got the glass morph
    /// between two items, whose middle is an EMPTY bubble — hidden while bar
    /// toasts covered the bell, plain to see once they left the bar. The
    /// system's own mute buttons keep their bubble and redraw the symbol
    /// (`setSymbolImage(_:contentTransition: .replace)`: the slash drawn
    /// across the bell).
    private lazy var muteItem = makeMuteItem()
    /// The conversation's mute; nil hides the bell.
    private var muted: Bool?
    /// While the viewer's own mute or unmute is on its way: a second tap does
    /// nothing. The bell shows the change at once (#2143).
    private var muteInFlight = false

    private var phase: ConversationThreadPhase = .loading
    private var messagesByID: [String: ConversationThreadMessage] = [:]
    /// Where each voice message was left, 0…1, for the conversation's life
    /// on screen (#2104): coming back to one mid-way shows — and plays from —
    /// where it was.
    private var voicePositions: [String: Double] = [:]
    /// Hold the empty field to record (#2102, #2183): every full
    /// conversation whose driver sends voice.
    private(set) var voiceComposer: VoiceComposer?
    /// The voice message the one player last spoke for: its position is kept
    /// when another starts.
    private var voiceShownID: String?
    private let voicePlayer = VoicePlayer.shared
    private let voicePlayed = VoicePlayedStore.shared
    /// The viewer's messages that just appeared on their way — they rise into
    /// place as their cell is configured (#719).
    private var arrivingIDs: Set<String> = []
    /// Messages that just replaced their pending row — they come up to full
    /// ink rather than cross-fading in (#719).
    private var deliveredIDs: Set<String> = []
    /// When each pending message began to rise: a delivery that lands
    /// mid-rise (a fast server) waits for the rise to land rather than
    /// swapping the row — and the stream's scroll — out from under it.
    private var arrivalStarts: [String: CFTimeInterval] = [:]
    /// The clock a rise is timed on. Tests stop it, so whether a delivery
    /// lands mid-rise never hangs on how fast the test runs.
    var mediaTime: () -> CFTimeInterval = CACurrentMediaTime

    /// How long a message may take to send before its row shows the loader
    /// (the owner, 2026-10-17): on a good connection a send lands within it
    /// and the time simply comes in — a loader there is noise. Tests set 0.
    var sendingLoaderDelay: TimeInterval = 0.4
    /// The phase held back until a rise lands; the newest one wins.
    private var deferredPhase: ConversationThreadPhase?
    /// Delivered messages whose pending row already played the delivery
    /// while the swap waited for its rise: they land plainly (#725).
    private var deliveredEarly: Set<String> = []
    private var peer = ConversationThreadPerson(id: nil, name: "", avatarURL: nil)
    /// The conversation is a group (#2214): the header is its identity, and
    /// each row is signed by its sender among `members`. Nil for a DM.
    private var group: ConversationThreadGroup?
    /// A channel's viewer who doesn't post (#2215): the bar in the
    /// composer's place. Built the first time one is needed.
    private var readerBar: ConversationReaderBar?
    /// Whether the reader bar shows — what it was last told, not
    /// `isHidden`, which stays false through its fade out (#2236).
    private var readerBarShown = false
    /// The reader bar's write is on its way (a join, a withdrawal).
    private var readerActionInFlight = false
    /// Where the viewer stands, while they don't post (#2215, #2217) — kept
    /// apart from the bar, which hides for a standing with nothing to offer.
    private var readerStanding: ConversationThreadReaderStanding?

    // MARK: The relation (#752)

    /// The pill's relation glyph, as a vertical post's author pill draws it:
    /// "+" (a tap follows), following, friends. Nil graphs draw none.
    private let socialGraph: (any SocialGraphWriting)?
    private let followRelations: (any SocialGraphReading)?
    /// Where the viewer stands with each person, the app's one copy
    /// (#2049): the pill starts from what is known there — the inbox row
    /// that opened the thread knew it — and follows every change to it, a
    /// follow from a profile card included.
    private let entities: EntityStore?
    private var peerObservation: EntityObservation?
    private var peerRelation: FollowRelation?
    /// Whom `peerRelation` was asked for, so a peer is asked once.
    private var relationAskedFor: ProfileID?
    /// A landed relation waiting for the navigation transition to end.
    private var landedRelationScheduled = false
    private var followInFlight = false
    /// Bumped by every ask and every follow: an answer from before either
    /// is stale — a read sent before a follow undid the follow (#752).
    private var relationGeneration = 0
    private var viewer = ConversationThreadPerson(id: nil, name: "You", avatarURL: nil)
    private var hasRenderedContent = false

    /// The day chip's size, for its bone.
    static let dayBoneSize = CGSize(width: 96, height: 26)
    /// Where the thread's last-known shape is kept (#1774). Injectable for
    /// tests.
    var presence: SectionPresenceStore = .shared
    /// How many messages the thread had last time; nil never seen.
    private var rememberedMessageCount: Int? {
        driver.presenceKey.flatMap { presence.count(screen: $0, section: "messages") }
    }
    /// Whether its newest messages had a picture last time.
    private var rememberedMedia: Bool {
        (driver.presenceKey.flatMap { presence.count(screen: $0, section: "media") } ?? 0) > 0
    }
    /// The skeleton's rows as last applied.
    private var skeletonRowCount = 0

    /// The first load's skeleton on the kit's timing (#1770): no bones for a
    /// thread that answers at once, held their minimum once up, and "taking
    /// longer" with Try Again after 10 s. Injectable so a test steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var skeletonGate: SkeletonGate = {
        let gate = SkeletonGate(clock: skeletonClock)
        gate.onSkeletonChange = { [weak self] _ in
            guard let self, case .loading = phase, !hasRenderedContent else { return }
            applySnapshot(animated: false)
        }
        gate.onTakingLonger = { [weak self] in
            self?.gaveUpWaiting = true
            self?.skeletonGate.finish { [weak self] in self?.showTakingLonger() }
        }
        return gate
    }()
    /// The first load ran past 10 s: the status stays, and a redraw while
    /// still loading does not bring the bones back, until Try Again.
    private var gaveUpWaiting = false
    /// First content arrived before the stream had a height to pin against —
    /// see `pinToTail`.
    private var owesTailPin = false
    private var hasEstablishedClearance = false
    /// Whether a short transcript starts from the bottom (#1799, the
    /// default since #1923). Settable for tests, before the
    /// view loads.
    var anchorsShortStream = true
    /// The room above a short transcript, worn in the top inset
    /// (`syncBottomAnchor`).
    private(set) var bottomAnchorSlack: CGFloat = 0
    private var newestID: String?
    /// The oldest message shown — older history landing above it is told
    /// apart from new messages landing below (#600).
    private var oldestID: String?
    private var pendingFlashID: String?
    private var lastPreviewSize: CGSize = .zero

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    init(
        driver: any ConversationThreadDriving,
        mode: ConversationThreadMode,
        prefill: String,
        imagePipeline: ImagePipeline,
        socialGraph: (any SocialGraphWriting)? = nil,
        followRelations: (any SocialGraphReading)? = nil,
        entities: EntityStore? = nil
    ) {
        self.entities = entities
        self.driver = driver
        self.mode = mode
        self.prefill = prefill
        self.imagePipeline = imagePipeline
        self.socialGraph = socialGraph
        self.followRelations = followRelations
        super.init(nibName: nil, bundle: nil)
        // In the initializer: a navigation controller reads it when the push
        // begins, and `viewDidLoad` can run inside that same push.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureCollectionView()
        observeContentSize()
        if mode == .full {
            configureComposer()
            configureToolbar()
            contextMenu.install(on: collectionView)
            contextMenu.menuProvider = { [weak self] indexPath in self?.menu(at: indexPath) }
            // A leftward swipe pushes the peer's profile (#1525).
            let arbiter = SwipeStageArbiter(host: self)
            arbiter.install(in: view)
            swipeArbiter = arbiter
        }
        configureNavigationItem()
        configureStatusLabel()
        configureOlderSpinner()
        bindDriver()
        applySnapshot(animated: false)
        driver.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard mode == .full else { return }
        // The footer belongs to this screen only — the inbox behind it has
        // none. Shown during the push so it slides in with the transition.
        navigationController?.setToolbarHidden(false, animated: animated)
        // Before the bars first lay it out, not only after: a budget that
        // arrives late is a bar that has already collapsed into a `•••`.
        fitTrailingRun()
        // And laid out at that width before the push's animation takes it:
        // the push fades the pill in, nothing inside it moves.
        peerPill.settleLayout()
        // Back from their profile, the relation may have moved.
        resolvePeerRelation(refresh: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back from a cancelled pop: the reader stays where they were while
        // the footer finishes coming back (see `heldPlace`).
        if let held = heldPlace {
            // Held through the footer's own return, which outlasts the pop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, heldPlace == held else { return }
                releaseHeldPlace()
            }
        }
        guard !hasAppeared else { return }
        hasAppeared = true
        // The rows that came on screen with it have sized themselves by now;
        // a turn later, the tail is the conversation's own again.
        DispatchQueue.main.async { [weak self] in self?.holdsTail = false }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Materials in a window only — built in init they stall headless CI.
        if composerBackdrop.superview != nil, composerBackdrop.effect == nil {
            composerBackdrop.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        contextMenu.endTextSelection()
        // Leaving the conversation stops its voice message (#2104), and keeps
        // a locked or paused take as its draft (#2102).
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            stopVoice()
            voiceComposer?.leave()
        }
        guard mode == .full else { return }
        // ⚠️ A POP THE FINGER DRIVES MAY BE CANCELLED: the footer goes and
        // comes back, and a transcript at its tail must not move for it (see
        // `heldPlace`). Held until the pop ends, or a while after a cancelled
        // one has the screen back.
        if let coordinator = transitionCoordinator, coordinator.isInteractive, hasRenderedContent,
           bottomAnchorSlack < 0.5 {
            // The clearance as it stands, kept with the safe area at its
            // least (the home indicator's alone): the inset makes up for it.
            let leastSafeArea = view.window?.safeAreaInsets.bottom ?? 0
            heldPlace = HeldPlace(
                offset: collectionView.contentOffset.y,
                contentHeight: collectionView.contentSize.height,
                inset: max(collectionView.contentInset.bottom, collectionView.adjustedContentInset.bottom - leastSafeArea)
            )
            holdPlace()
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, let held = heldPlace else { return }
                // Completed (a push to the profile stays under this screen):
                // the inset goes back now, or the way back would carry the
                // transcript by the difference. Cancelled: after the footer's
                // return (`viewDidAppear`), and in any case soon.
                if !context.isCancelled { return releaseHeldPlace() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, heldPlace == held else { return }
                    releaseHeldPlace()
                }
            }
        }
        // Taken away on the way out, or the inbox inherits an empty bar.
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard mode == .full else {
            if owesTailPin { pinToTail() }
            // A peek's platter settles its size over several passes; keep the
            // tail pinned until it does, never while a finger is down.
            if collectionView.bounds.size != lastPreviewSize {
                lastPreviewSize = collectionView.bounds.size
                if hasRenderedContent, !collectionView.isTracking { scrollToBottom(animated: false) }
            }
            return
        }
        // ⚠️ NOT UNDER A PUSH'S ANIMATION (the owner's device, 2026-11-02):
        // the push lays the screen out inside its own animation block, and the
        // offset set here rode it — the conversation came in high and
        // scrolled down to its place. Under a transition it is simply where
        // it rests from the first frame; the keyboard's travel keeps riding
        // the keyboard (no transition then).
        let layOut = {
            self.syncBottomClearance()
            // The opening starts at the tail (#2121): see `aimAtEstimatedTail`.
            if self.owesTailPin, self.hasEstablishedClearance { self.aimAtEstimatedTail() }
            // In the same pass as the clearance (#1799): a composer the
            // keyboard or a growing field moves carries a short transcript
            // with it, the slack absorbing the travel. A finger scrubbing the
            // keyboard down owns the offset; the bounce back puts it where it
            // rests.
            self.syncBottomAnchor(movesOffset: !self.collectionView.isTracking)
            self.syncDayItem()
            // After the clearance, in the same pass: see `pinToTail`.
            if self.owesTailPin { self.pinToTail() }
            // Every pass while it is held: the footer's return moves the
            // safe area through passing values, and the last pass is right.
            if self.heldPlace != nil, self.hasRenderedContent { self.holdPlace() }
        }
        if transitionCoordinator != nil { UIView.performWithoutAnimation(layOut) } else { layOut() }
    }

    /// Where a day's first message rests after a tap on the bar's day,
    /// below the bar's bottom: the stream's own top breath (#750).
    static var dayStartLanding: CGFloat { SnapCommentsLayout.streamTopBreath }

    /// The day on screen, as a bar item right of the back button (#750): a system
    /// glass bubble, interactive. A tap scrolls to that day's first message,
    /// as a search section's pill does. The flow keeps its own day chips,
    /// unpinned (#755).
    ///
    /// ⚠️ ONE ITEM PER DAY, EACH WITH ITS OWN IDENTIFIER (#755), as the bell
    /// (#729): a title edited in place swaps in a frame; a new item under a
    /// new identifier gets the native Liquid Glass morph.
    private var dayItem = UIBarButtonItem()
    private var dayItemShown = false
    private var dayShown: Date?

    /// The day of the last chip gone under the header; none before one has.
    private func syncDayItem() {
        guard mode == .full else { return }
        guard hasRenderedContent, let day = dayOnScreen() else { return showDayItem(false) }
        if day != dayShown {
            dayShown = day
            dayItem = makeDayItem(day)
            // A change of day while it shows morphs, glass to glass.
            if dayItemShown { scheduleDayPlacement() }
        }
        showDayItem(true)
    }

    /// Puts the bar's day where the state says, ONCE, on the next turn
    /// (#756):
    /// - the next turn: this runs from scrolls and layouts that a diffable
    ///   `apply(animatingDifferences: false)` drives inside
    ///   `performWithoutAnimation`, which swallowed the transition;
    /// - once: opening on a long thread, the item appears and changes day in
    ///   the same turn, and a second `setRightBarButtonItems` cut the first
    ///   one's appearance short — the item popped in on the device.
    private func scheduleDayPlacement() {
        guard view.window != nil else { return placeDayItem(animated: false) }
        guard !dayPlacementScheduled else { return }
        dayPlacementScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.placeDayAfterTransition()
        }
    }

    /// ⚠️ NOT DURING A PUSH (#756): items set while the bar is in its push
    /// transition land with it, unanimated, when it ends — the day popped in
    /// on the device just after the push. A placement due mid-transition
    /// waits for its end, then animates.
    private func placeDayAfterTransition() {
        // A coordinator that does not queue the completion (`false`) would
        // leave the placement pending for good — every later day change
        // returning early: place it now instead.
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
               // Off the completion's turn, which still belongs to the transition.
               DispatchQueue.main.async { self?.placeDayAfterTransition() }
           }) {
            debugDayPlacementWaits += 1
            return
        }
        dayPlacementScheduled = false
        placeDayItem(animated: true)
    }

    private var dayPlacementScheduled = false

    /// A day placement on its way, how many transitions it waited for, and
    /// whether one runs now. Tests.
    var debugDayPlacement: (scheduled: Bool, waits: Int, inTransition: Bool) {
        (dayPlacementScheduled, debugDayPlacementWaits, transitionCoordinator != nil)
    }
    private var debugDayPlacementWaits = 0

    private func makeDayItem(_ day: Date) -> UIBarButtonItem {
        let title = DayTitleFormatter.title(for: day, now: dayClock())
        let item = UIBarButtonItem(
            title: title, image: nil,
            primaryAction: UIAction { [weak self] _ in self?.scrollToDayStart() }
        )
        item.identifier = Self.dayItemID(day)
        item.tintColor = .label
        item.accessibilityLabel = title
        item.accessibilityHint = "Scrolls to the first message of the day"
        return item
    }

    /// What "now" is for the day titles — the clock, unless a test fixes it.
    /// ⚠️ A run crossing midnight read the clock twice, the seed's day and the
    /// title's on either side of it: "October 8" where "Yesterday" was due.
    var dayClock: () -> Date = Date.init

    static func dayItemID(_ day: Date) -> String {
        "conversation.day.\(Int(day.timeIntervalSince1970))"
    }

    /// ⚠️ THE DAY OF THE LAST CHIP THAT WENT UNDER THE HEADER (#755, the
    /// owner's call 2026-10-09), not the day of the first message: the bar
    /// takes over a chip once it has scrolled away. At the start of the
    /// conversation no chip has gone under yet, so there is no item; on a
    /// long conversation opened at its tail, it is the current day's.
    private func dayOnScreen() -> Date? {
        let line = view.safeAreaInsets.top
        let probe = collectionView.convert(CGPoint(x: collectionView.bounds.midX, y: line), from: view)
        let sections = dataSource.snapshot().sectionIdentifiers
        var passed: Date?
        for (index, section) in sections.enumerated() {
            guard case .day(let day) = section,
                  let chip = collectionView.layoutAttributesForSupplementaryElement(
                      ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: index)
                  )?.frame
            else { continue }
            // Under the header once its middle is past the bar's bottom.
            guard chip.midY <= probe.y else { break }
            passed = day
        }
        return passed
    }

    private func showDayItem(_ shown: Bool) {
        guard shown != dayItemShown else { return }
        dayItemShown = shown
        // UIKit's own bar-item appearance, not a pop (#755, #756).
        scheduleDayPlacement()
    }

    /// Scrolls to the start of the bar's day — its chip in the flow, then
    /// its first message — landing just below the bar (#750, #755).
    private func scrollToDayStart() {
        holdsTail = false
        guard let day = dayShown,
              let section = dataSource.snapshot().sectionIdentifiers.firstIndex(of: .day(day)),
              collectionView.numberOfItems(inSection: section) > 0
        else { return }
        let start = IndexPath(item: 0, section: section)
        let chip = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: DayPillHeaderView.elementKind, at: start
        )?.frame
        guard let frame = chip ?? collectionView.layoutAttributesForItem(at: start)?.frame else { return }
        let landing = view.safeAreaInsets.top + Self.dayStartLanding
        let insets = collectionView.adjustedContentInset
        let maxOffset = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        let offset = min(max(frame.minY - landing, -insets.top), maxOffset)
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: true)
    }

    /// Whether the bar's day shows, and what it says. Tests.
    /// `inBar`: whether the bar holds it yet — a turn after `shown`.
    var debugDayItem: (shown: Bool, title: String?, item: UIBarButtonItem, inBar: Bool) {
        let inBar = navigationItem.leftBarButtonItems?.contains { $0 === dayItem } ?? false
        return (dayItemShown, dayItem.title, dayItem, inBar)
    }

    /// What a tap on the bar's day does. Tests.
    func debugTapDayItem() { scrollToDayStart() }

    // MARK: - Setup

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInset.top = SnapCommentsLayout.streamTopBreath
        // ⚠️ NO BLUR UNDER THE HEADER (#750, the owner's call 2026-10-09,
        // back from #741): the messages run up under the day
        // as on every other screen; the window's status-bar blur
        // (`StatusBarBlurView`) is the only material up there. See
        // `prefersClearTopEdge`.
        collectionView.prefersClearTopEdge()
        collectionView.delegate = self
        // No pull-to-refresh (asked 2026-10-02): a conversation is live — what
        // arrives is pushed into it — and a loader at the top of the thread
        // only competed with reading back through it.
        if mode == .preview {
            // The tail never sits flush on the platter's edge.
            collectionView.contentInset.bottom = Spacing.md
        } else {
            // A bare tap on the stream retires the keyboard, as on the post
            // — and so does a tap on a message's body (`retireKeyboardOr`),
            // whose own reply tap otherwise wins the touch.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleStreamTap))
            tap.cancelsTouchesInView = false
            collectionView.addGestureRecognizer(tap)
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configureDataSource()
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let policy = headerPolicy
        let isFull = mode == .full
        return UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg
            )
            if policy.daySections {
                // The day chip where each day starts.
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)
                    ),
                    elementKind: DayPillHeaderView.elementKind,
                    alignment: .top
                )
                // ⚠️ NOT STICKY ON A FULL THREAD (#755, the owner's call
                // 2026-10-09): the chip scrolls with its day; the bar's day
                // item says which day is on screen. A peek has no bar, so
                // its chip stays pinned.
                header.pinToVisibleBounds = !isFull
                header.zIndex = 2
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }

    private func configureDataSource() {
        let messageCell = UICollectionView.CellRegistration<ThreadRowCell, String> { [weak self] cell, _, id in
            self?.configure(cell, messageID: id)
        }
        let skeletonCell = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, index in
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            // A message row's shape (#1774): no like column, and a picture
            // where the conversation had pictures last time — on the newest
            // bone row, the one nearest the tail.
            let showsMedia = self?.rememberedMedia == true && index == (self?.skeletonRowCount ?? 0) - 1
            let row = CommentSkeletonRowView(index: index, reservesLikeColumn: false, showsMedia: showsMedia)
            row.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                row.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.lg),
            ])
        }
        // The day chip's bone, centred where the chip will stand (#1774).
        let skeletonDayCell = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, _ in
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let bone = SkeletonBoneView(rounding: .capsule)
            bone.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(bone)
            NSLayoutConstraint.activate([
                bone.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: Spacing.xs),
                bone.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -Spacing.md),
                bone.centerXAnchor.constraint(equalTo: cell.contentView.centerXAnchor),
                bone.widthAnchor.constraint(equalToConstant: Self.dayBoneSize.width),
                bone.heightAnchor.constraint(equalToConstant: Self.dayBoneSize.height),
            ])
        }
        // A system line (#2214): centred, quiet, no author.
        let systemCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            var content = UIListContentConfiguration.cell()
            content.text = self?.messagesByID[id]?.body
            content.textProperties.font = .appFont(forTextStyle: .footnote)
            content.textProperties.color = .secondaryLabel
            content.textProperties.alignment = .center
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: Spacing.xs, leading: Spacing.lg, bottom: Spacing.md, trailing: Spacing.lg
            )
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
            cell.isUserInteractionEnabled = false
        }
        let emptyCell = UICollectionView.CellRegistration<CommentsEmptyPageCell, Item> { [weak self] cell, _, _ in
            let copy = ConversationThreadViewController.emptyPageCopy
            cell.configure(
                symbolName: copy.symbol,
                title: copy.title,
                subtitle: copy.subtitle,
                height: self?.emptyPageHeight() ?? SnapCommentsLayout.emptyPageFallbackHeight
            )
        }
        let dayHeader = UICollectionView.SupplementaryRegistration<DayPillHeaderView>(
            elementKind: DayPillHeaderView.elementKind
        ) { [weak self] header, _, indexPath in
            guard let self,
                  case .day(let day) = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            header.configure(title: DayTitleFormatter.title(for: day, now: dayClock()))
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .message(let id):
                collectionView.dequeueConfiguredReusableCell(using: messageCell, for: indexPath, item: id)
            case .skeleton(let index):
                collectionView.dequeueConfiguredReusableCell(using: skeletonCell, for: indexPath, item: index)
            case .skeletonDay:
                collectionView.dequeueConfiguredReusableCell(using: skeletonDayCell, for: indexPath, item: 0)
            case .empty:
                collectionView.dequeueConfiguredReusableCell(using: emptyCell, for: indexPath, item: item)
            case .system(let id):
                collectionView.dequeueConfiguredReusableCell(using: systemCell, for: indexPath, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: dayHeader, for: indexPath)
        }
    }

    /// The text page's composer, at the text page's resting place: just above
    /// the footer for good — only its input row rides the keyboard.
    private func configureComposer() {
        composeBar.defaultPlaceholder = "Message…"
        composeBar.draftText = prefill
        composeBar.onSend = { [weak self] text in self?.driver.send(text) }
        // The reply state's natural exit, as on the post: the keyboard retired
        // over an empty field.
        composeBar.onIdleDismiss = { [weak self] in self?.driver.cancelReply() }
        // No column: a conversation has nothing to like, and no slot.
        composeBar.configuration = composerConfiguration()
        installVoiceComposer()
        renderPinned(isPinned)
        returnButton.addAction(UIAction { [weak self] _ in self?.scrollToBottom(animated: true) }, for: .primaryActionTriggered)
        composeBar.onVoiceOverlayChange = { [weak self] records in
            guard let self, records != composerRecords else { return }
            composerRecords = records
            renderReturn()
        }

        composerBackdrop.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        composerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBackdrop)
        view.addSubview(composeBar)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(returnButton)
        // The BAR rests on the safe area, which the footer toolbar inflates,
        // and never moves: at rest the input row sits `glassGap` above the
        // toolbar's glass and the bar lifts its own column
        // (`SnapActionColumn`). The keyboard guide, measured from the screen's
        // edge, lifts the input row alone the moment the keyboard rises past
        // it (`riseWithKeyboard`), its own action bubble with it.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            composeBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -SnapActionColumn.trailingInset
            ),
            // One breath over the toolbar, as a post's composer rests (#1722):
            // the pin keeps the feed's sound bubble's place.
            composeBar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -(SnapActionColumn.inputRestingGap + SnapActionColumn.bottomBreath)
            ),
            composerBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            returnButton.trailingAnchor.constraint(equalTo: composeBar.trailingAnchor),
            returnButton.widthAnchor.constraint(equalToConstant: SnapActionColumn.bubbleSize),
            returnButton.heightAnchor.constraint(equalToConstant: SnapActionColumn.bubbleSize),
        ])
        composerFoot = [
            // From the INPUT ROW, as on the post: the lifted slot floats in
            // the band's ramp, and the band rides the keyboard with the row.
            composerBackdrop.topAnchor.constraint(
                equalTo: composeBar.inputRowTopAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
            // Over the row's own bubble, a breath above the row: it rides the
            // keyboard with it.
            returnButton.bottomAnchor.constraint(equalTo: composeBar.inputRowTopAnchor, constant: -Spacing.md),
        ]
        // Neither composer nor reader bar (#2236): the band and the way
        // back come down to the toolbar, where the composer would have
        // stood — nothing floats over the last message.
        bareFoot = [
            composerBackdrop.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
            returnButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -(SnapActionColumn.bottomBreath + Spacing.md)
            ),
        ]
        NSLayoutConstraint.activate(composerFoot)
        composeBar.riseWithKeyboard(of: view.keyboardLayoutGuide)
    }

    /// The band's top and the way back's foot, on the composer's input row
    /// (which the reader bar stands in for)…
    private var composerFoot: [NSLayoutConstraint] = []
    /// …or on the toolbar, while the footer is bare (#2236).
    private var bareFoot: [NSLayoutConstraint] = []

    /// The footer holds neither the composer nor the reader bar (#2236): a
    /// channel's subscriber, a group closed to its reader. The thread takes
    /// the composer's height back, and the footer is the pill and the ⋯, as
    /// on a post.
    private var footerIsBare: Bool { mode == .full && composeBar.isHidden && !readerBarShown }

    /// Puts the band and the way back on the composer's row, or on the
    /// toolbar while the footer is bare. The caller lays out.
    private func placeFooterFoot() {
        guard !composerFoot.isEmpty else { return }
        let bare = footerIsBare
        guard bareFoot[0].isActive != bare else { return }
        if bare {
            NSLayoutConstraint.deactivate(composerFoot)
            NSLayoutConstraint.activate(bareFoot)
        } else {
            NSLayoutConstraint.deactivate(bareFoot)
            NSLayoutConstraint.activate(composerFoot)
        }
    }

    /// The post's footer, with the peer's pill where the post's author pill
    /// is (#671): `[peer pill] … [pin · bell] [⋯]` (#2305, #2344). The emote strip
    /// that held the slot is gone — the composer's own emote button is the
    /// way to emotes — and the camera and the library left for the
    /// composer's row (`attachmentSources`), the pin and the bell coming
    /// down from the top bar into their place.
    ///
    /// What the footer holds follows the kind of conversation, and so do
    /// the composer's attachments (a channel's reader sends nothing): both
    /// are set here.
    private func configureToolbar() {
        let more = SnapFooterToolbar.makeMoreItem(menu: overflowMenu())
        moreItem = more
        toolbarItems = footerItems()
        composeBar.configuration = composerConfiguration()
        toolbarShape = ToolbarShape(
            isChannel: group?.isChannel == true, isGroup: group != nil, canPost: group?.canPost != false
        )
    }

    /// The peer pill's item, made once: the footer rebuilt for the bell
    /// keeps it.
    private lazy var peerPillItem = BarItems.container(id: "conversation.peer-pill", view: peerPill)

    /// `[peer pill] … [pin · bell] [⋯]` (#2344, the owner 2026-11-12): the
    /// pin and the bell share ONE platter — neighbouring items, which the
    /// bar joins by itself — and ⋯ keeps its own bubble behind the
    /// separator. (Reverses #2305's bubble each, 2026-11-07.) The pin
    /// always (disabled on a draft), the bell once there is a conversation
    /// to mute: the platter grows or shrinks for it by the bar's own
    /// animation (`placeFooterItems`). A channel's reader keeps both, in
    /// the same platter.
    private func footerItems() -> [UIBarButtonItem] {
        var actions = [pinItem]
        if muted != nil { actions.append(muteItem) }
        return [peerPillItem] + SnapFooterToolbar.trailingItems(actions: actions, more: moreItem)
    }

    /// The footer again — the bell come or gone. Rebuilt and handed to the
    /// bar, which animates the change (R3); nothing when its items are the
    /// same, which would restart a transition already running (#756).
    private func placeFooterItems() {
        guard mode == .full, moreItem != nil else { return }
        let items = footerItems()
        let current = toolbarItems ?? []
        guard items.compactMap(\.identifier) != current.compactMap(\.identifier) else { return }
        let animated = view.window != nil && transitionCoordinator == nil
        setToolbarItems(items, animated: animated)
    }

    /// The footer's ⋯, kept so its menu follows the standing in place
    /// (#2236): rebuilding the toolbar for a new entry would re-lay its
    /// glass.
    private var moreItem: UIBarButtonItem?

    /// The ⋯ menu: the conversation's info first; then, for a reader, the
    /// way out (#2236) — a section of its own, last.
    ///
    /// ⚠️ THE WAY OUT IS THE MENU'S, NOT THE BAR'S (#2236, the owner
    /// 2026-11-10): a destructive, rarely used action doesn't sit under the
    /// thumb on every read (Telegram, WhatsApp and Instagram all leave a
    /// channel from its menu or its details). Each still asks first
    /// (`confirmReader`). An owner or an admin posts, so they have no
    /// standing and no Leave here: an owner hands the channel over first,
    /// from the info screen.
    private func overflowMenu() -> UIMenu {
        let info: UIAction
        if group?.isChannel == true {
            // A channel's menu opens its info (#2215).
            info = UIAction(title: "Channel Info", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self else { return }
                self.driver.didTapGroupInfo(from: self)
            }
        } else if group != nil {
            // A group has no one profile to open: its info (#2236).
            info = UIAction(title: "Group Info", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self else { return }
                self.driver.didTapGroupInfo(from: self)
            }
        } else {
            info = UIAction(title: "View Profile", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                self?.driver.didTapIdentity()
            }
        }
        guard let exit = ConversationReaderExit(standing: readerStanding) else { return UIMenu(children: [info]) }
        let leave = UIAction(
            title: exit.title, image: UIImage(systemName: exit.symbol),
            attributes: exit.isDestructive ? .destructive : []
        ) { [weak self] _ in
            self?.performReaderExit(exit)
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [info]),
            UIMenu(options: .displayInline, children: [leave]),
        ])
    }

    /// The ⋯ menu again, for a new standing or a new kind of conversation.
    private func refreshOverflowMenu() {
        moreItem?.menu = overflowMenu()
    }

    /// What the footer was last built for (#2215): rebuilt only when a
    /// channel's descriptor changes what it holds.
    private struct ToolbarShape: Equatable {
        var isChannel = false
        var isGroup = false
        var canPost = true
    }
    private var toolbarShape = ToolbarShape()

    /// The camera and the library (#681), in the composer's row since #2305:
    /// `[avatar][field][📷 🖼][☺]` — one capsule, folded into the own bubble
    /// while the reader writes (#2344) — for a
    /// thread whose driver sends media. A list of sources, not a pair of
    /// buttons: the conversation's declared attachments (#2308).
    /// The conversation's composer contract (#2308): what differs from a
    /// post's comments, and nothing else — a message's voice (five minutes)
    /// where the screen is the full conversation and its driver sends voice,
    /// the camera and the library (#2305), no column.
    func composerConfiguration() -> ComposerConfiguration {
        .conversation(voice: recordsVoice ? .message : .none, attachments: attachmentSources())
    }

    /// Whether the field's hold records a voice message (#2102).
    var recordsVoice: Bool { mode == .full && driver.sendsVoice }

    private func attachmentSources() -> [ComposerAttachmentSource] {
        // A channel's reader sends nothing (#2215).
        guard mode == .full, driver.sendsMedia, group?.canPost != false else { return [] }
        return [
            ComposerAttachmentSource(id: Self.cameraID, symbol: "camera", accessibilityLabel: "Camera") { [weak self] in
                self?.pickMedia(.camera)
            },
            ComposerAttachmentSource(
                id: Self.libraryID, symbol: "photo.on.rectangle", accessibilityLabel: "Photo Library"
            ) { [weak self] in
                self?.pickMedia(.library)
            },
        ]
    }

    static let cameraID = "conversation.camera"
    static let libraryID = "conversation.library"

    private func pickMedia(_ source: ConversationThreadMediaSource) {
        view.endEditing(true)
        driver.pickMedia(source, from: self)
    }

    /// A media bubble was tapped: a failed one is sent again, a sent one
    /// opens full screen.
    private func tapMedia(of messageID: String, in cell: ThreadRowCell) {
        guard let message = messagesByID[messageID], let media = message.media else { return }
        switch message.delivery {
        case .failed:
            driver.retry(messageID)
        case .sending:
            break
        case .sent:
            guard presentedViewController == nil,
                  let viewer = ThreadMediaViewer.make(media, shownImage: cell.mediaView.image, pipeline: imagePipeline)
            else { return }
            present(viewer, animated: true)
        }
    }

    private func configureNavigationItem() {
        // The text page's bar: transparent, so the window's status-bar band
        // is the only material up there, and set per item so the inbox
        // behind keeps its own.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        // ⚠️ NO TITLE SHOWN IN THE CENTRE (#750, the owner's call 2026-10-09,
        // over #738): the correspondent is the toolbar's pill; the bar
        // carries the back button and the day — the pin and the bell went
        // down to the footer (#2305), so the top bar is calm.
        navigationItem.titleView = nil
        navigationItem.title = nil

        peerPill.setFollowBadge(.none)
        peerPill.setOverMedia(false)
        // A person beside content (#2145): a tap opens the peer's profile
        // card (#1524), a hold pushes the profile — it had none (#2144). A
        // group, or a peer still resolving, takes neither (the pill shows no
        // author then).
        peerPill.onAuthorTapped = { [weak self] _ in self?.driver.didTapIdentityPill() }
        peerPill.onAuthorLongPressed = { [weak self] _ in self?.driver.didTapIdentity() }
        peerPill.onFollowTapped = { [weak self] id in self?.followPeer(id) }
        // The pill is the toolbar's (#671); a preview (no toolbar) keeps it
        // in the bar. No points badge on a conversation (#738), and no pin
        // or bell either: both are the footer's (#2305).
        navigationItem.rightBarButtonItems = pillRidesToolbar ? [] : [peerPillItem]
        // The day stands right of the back button (the owner, 2026-11-07).
        navigationItem.leftItemsSupplementBackButton = true
    }

    /// How many animated placements the bar took. Tests.
    private(set) var debugAnimatedBarPlacements = 0

    /// The day, right of the back button (the owner, 2026-11-07; it stood
    /// left of the bell). A placement on its way, unanimated (`scheduled`),
    /// leaves the day as it stands rather than popping it in.
    private func placeDayItem(animated: Bool) {
        guard mode == .full else { return }
        let current = navigationItem.leftBarButtonItems ?? []
        if dayPlacementScheduled, !animated { return }
        let items = dayItemShown ? [dayItem] : []
        // The same items again would restart — and cut short — a transition
        // already running (#756).
        guard items.count != current.count || zip(items, current).contains(where: { $0 !== $1 }) else { return }
        if animated { debugAnimatedBarPlacements += 1 }
        navigationItem.setLeftBarButtonItems(items, animated: animated)
    }

    /// The bell: a tap toggles the mute it shows when tapped, a long press
    /// offers how long (#729). Made once; `applyBellLook` dresses it for the
    /// mute. The action carries no image (`BarItems.icon`'s note: an
    /// action's image is re-applied to its item when it fires).
    private func makeMuteItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: nil,
            image: UIImage(systemName: "bell"),
            primaryAction: UIAction { [weak self] _ in
                guard let self, let muted else { return }
                setMuted(!muted, until: nil)
            },
            menu: nil
        )
        item.identifier = Self.bellID
        item.tintColor = .label
        item.accessibilityLabel = "Notifications"
        return item
    }

    /// The bell's glyph, spoken value and menu for the mute now. Animated:
    /// the symbol is replaced in place, its bubble kept (see `muteItem`).
    private func applyBellLook(muted: Bool, animated: Bool) {
        let image = UIImage(systemName: muted ? "bell.slash" : "bell")
        if animated, let image {
            muteItem.setSymbolImage(image, contentTransition: .replace)
        } else {
            muteItem.image = image
        }
        muteItem.accessibilityValue = muted ? "Muted" : "On"
        muteItem.menu = muteMenu(muted: muted)
    }

    static let bellID = "conversation.bell"

    /// How long a mute lasts, as the long press offers it (#729): the
    /// shared bell's (`MuteMenu`, #2237), so a duration added there shows
    /// here and on a group's or a channel's info screen alike.
    static let muteDurations: [(title: String, toast: String, seconds: TimeInterval?)] =
        MuteMenu.durations.map { (title: $0.title, toast: $0.toast, seconds: $0.seconds) }

    /// The shared bell menu (`MuteMenu`, #2237).
    private func muteMenu(muted: Bool) -> UIMenu {
        MuteMenu.make(muted: muted) { [weak self] duration in
            self?.setMuted(true, until: duration.end(), toast: duration.toast)
        } onUnmute: { [weak self] in
            self?.setMuted(false, until: nil)
        }
    }

    /// A message's Copy says so (#803): the pasteboard is off-screen, and a
    /// menu that closes on nothing reads as a tap that missed. Internal for
    /// tests.
    func confirmCopied() {
        Feedback.success("Copied", symbol: "doc.on.doc.fill", from: self)
    }

    /// Mutes or unmutes through the driver, and says so (#729).
    ///
    /// ⚠️ SAID ONCE THE SERVER HAS ANSWERED (#802), never on the tap. The
    /// toast waits for the write, and a refusal gets a failure toast instead
    /// of a confirmation of something that did not happen.
    ///
    /// THE BELL CHANGES AT ONCE (#2143): the driver's mute is optimistic, and
    /// no toast covers the bell any more, so it shows the change on the tap
    /// and the toast says what happened; a refusal rolls it back (the driver
    /// does) and says why.
    ///
    /// A mute is said with Undo (#957): optimistic + compensating — Undo
    /// turns the notifications back on, and a refused unmute is said.
    private func setMuted(_ mute: Bool, until: Date?, toast: String? = nil) {
        guard !muteInFlight else { return }
        muteInFlight = true
        driver.setMuted(mute, until: until) { [weak self] confirmed in
            guard let self else { return }
            muteInFlight = false
            if confirmed, mute {
                Feedback.undoable(
                    toast ?? "Notifications muted",
                    symbol: "bell.slash.fill",
                    from: self,
                    commit: {},
                    undo: { [weak self] in self?.undoMute() }
                )
            } else if confirmed {
                Feedback.success(
                    toast ?? (mute ? "Notifications muted" : "Notifications on"),
                    symbol: mute ? "bell.slash.fill" : "bell.fill",
                    from: self
                )
            } else {
                Feedback.failure(
                    mute ? "Couldn't mute notifications" : "Couldn't turn notifications on",
                    from: self
                )
            }
        }
    }

    /// A mute's Undo: the compensating unmute — the bell is the answer, said
    /// in words only if refused.
    private func undoMute() {
        driver.setMuted(false, until: nil) { [weak self] confirmed in
            guard let self, !confirmed else { return }
            Feedback.failure("Couldn't turn notifications on", from: self)
        }
    }

    /// The bell follows the conversation's mute; it appears once there is a
    /// conversation to mute and leaves if there is none — on the footer,
    /// between the pin and ⋯ (#2305).
    private func renderMuted(_ muted: Bool?) {
        let was = self.muted
        self.muted = muted
        guard let muted else {
            if was != nil {
                fitTrailingRun()
                placeFooterItems()
            }
            return
        }
        guard was != muted else { return }
        // A change redraws the glyph in place; a first appearance lands.
        applyBellLook(muted: muted, animated: was != nil)
        if was == nil {
            fitTrailingRun()
            placeFooterItems()
        }
    }

    #if DEBUG
    /// The bell on the footer, nil while there is none. Tests.
    var debugMuteItem: UIBarButtonItem? {
        toolbarItems?.first { $0 === muteItem }
    }

    /// What a tap on the bell does. Tests.
    func debugTapBell() {
        guard let muted else { return }
        setMuted(!muted, until: nil)
    }

    /// What picking the long-press menu's `index`th duration does. Tests.
    func debugPickMuteDuration(_ index: Int) {
        let duration = Self.muteDurations[index]
        setMuted(true, until: duration.seconds.map { Date().addingTimeInterval($0) }, toast: duration.toast)
    }
    #endif

    private func configureStatusLabel() {
        statusView.isHidden = true
        statusView.constrain(in: view) { parent in
            statusView.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor)
            // Above the keyboard, so a raised composer never sits on it.
            statusView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
            statusView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            statusView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        }
    }

    private func bindDriver() {
        driver.onPhaseChange = { [weak self] phase in self?.render(phase) }
        driver.onPeerChange = { [weak self] person in self?.adoptPeer(person) }
        driver.onGroupChange = { [weak self] group in self?.adoptGroup(group) }
        driver.onViewerChange = { [weak self] person in self?.adoptViewer(person) }
        driver.onReplyStateChange = { [weak self] draft in self?.renderReply(draft) }
        driver.onActionNotice = { [weak self] title, message in self?.presentNotice(title, message) }
        driver.onPinnedChange = { [weak self] pinned in self?.renderPinned(pinned) }
        driver.onMutedChange = { [weak self] muted in self?.renderMuted(muted) }
        driver.onLoadingOlderChange = { [weak self] loading in self?.setLoadingOlder(loading) }
    }

    private func configureOlderSpinner() {
        olderSpinner.hidesWhenStopped = true
        olderSpinner.isUserInteractionEnabled = false
        olderSpinner.constrain(in: view) { parent in
            olderSpinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            olderSpinner.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
        }
    }

    /// Never in a peek, which pages nothing.
    private func setLoadingOlder(_ loading: Bool) {
        guard mode == .full else { return }
        if loading { olderSpinner.startAnimating() } else { olderSpinner.stopAnimating() }
    }

    /// Whether the top of the thread says older history is on its way.
    var isShowingOlderSpinner: Bool { olderSpinner.isAnimating }

    // MARK: - Render

    private func render(_ phase: ConversationThreadPhase) {
        // ⚠️ THE FIRST LOAD'S SKELETON IS THE GATE'S (#1770): what answers
        // after the bones came waits out their minimum — the newest answer,
        // once.
        guard case .loading = phase else {
            return skeletonGate.finish { [weak self] in self?.renderNow(phase) }
        }
        if !hasRenderedContent, !gaveUpWaiting { skeletonGate.begin() }
        renderNow(phase)
    }

    /// "Taking longer than usual", the bones gone, and Try Again.
    private func showTakingLonger() {
        guard case .loading = phase, !hasRenderedContent else { return }
        applySnapshot(animated: false)
        statusView.configure(
            symbolName: TakingLongerCopy.symbol, title: TakingLongerCopy.title,
            subtitle: "The messages are still on their way.",
            actionTitle: TakingLongerCopy.action, actionHandler: { [weak self] in
                guard let self else { return }
                gaveUpWaiting = false
                statusView.isHidden = true
                skeletonGate.begin()
                applySnapshot(animated: false)
                driver.refresh()
            }
        )
        if composerBackdrop.superview === view { view.insertSubview(statusView, belowSubview: composerBackdrop) }
        statusView.isHidden = false
    }

    private func renderNow(_ phase: ConversationThreadPhase) {
        // ⚠️ A DELIVERY PLAYS ON THE PENDING ROW ON SCREEN, and the delivered
        // row takes its place only once it has played: the loader out, THEN
        // the time in (the owner, 2026-10-17). Played on the delivered row
        // instead, a freshly dequeued cell ran it before it was on screen —
        // the time came in over the loader — and a swap mid-reveal showed
        // the time at once. Mid-rise, the swap waits for the rise as well.
        let rise = riseStillLanding(before: phase)
        let delivering = playEarlyDeliveries(in: phase)
        if rise != nil || delivering {
            let wait = max(rise ?? 0, delivering ? ThreadRowCell.deliveryRevealDuration : 0)
            let pending = deferredPhase
            deferredPhase = phase
            guard pending == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, let held = self.deferredPhase else { return }
                self.deferredPhase = nil
                self.render(held)
            }
            return
        }
        deferredPhase = nil
        self.phase = phase
        switch phase {
        case .loading:
            statusView.isHidden = !gaveUpWaiting || hasRenderedContent
        case .failed(let message):
            // ⚠️ A WAY OUT (#797). It said "Pull to retry" on a screen with no
            // pull — by design (the composer owns the bottom edge) — so a
            // failed first load was a dead end until the viewer backed out.
            statusView.configure(
                symbolName: "exclamationmark.triangle", title: message,
                actionTitle: "Try Again", actionHandler: { [weak self] in
                    self?.statusView.setActionBusy(true)
                    self?.driver.refresh()
                }
            )
            // Beneath the composer, which stays live on a failure: its taps
            // are never the empty state's.
            if composerBackdrop.superview === view { view.insertSubview(statusView, belowSubview: composerBackdrop) }
            statusView.isHidden = hasRenderedContent
        case .content(let messages):
            statusView.isHidden = true
            // The shape the next cold load's skeleton takes (#1774).
            if let key = driver.presenceKey {
                presence.remember(messages.count, screen: key, section: "messages")
                let pictures = messages.suffix(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: view.bounds.height))
                    .contains { $0.media != nil }
                presence.remember(pictures ? 1 : 0, screen: key, section: "media")
            }
            let before = messagesByID
            messagesByID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            noteSendTransitions(from: before, to: messages)
        }

        let isFirstContent = !hasRenderedContent
        // Older history landing above (#600): applied without animation and
        // with the message under the reader's eye held where it is.
        let anchor = olderHistoryAnchor(for: phase)
        // A pending row turning into its delivered message is a swap, not a
        // change: animated, the two cross-fade (#719). ⚠️ `swappedIDs`, not
        // `deliveredIDs`: a delivery that landed mid-rise plays on the
        // pending row and never enters `deliveredIDs` — and its swap
        // cross-faded, a dim on the row and its avatar (#756).
        // ⚠️ AND NOT WHILE THE SCREEN IS COMING IN: a refresh landing under the
        // push re-laid the rows out animated, so the conversation moved as it
        // arrived. Nothing the viewer has seen changes then.
        let animatedApply = hasRenderedContent && anchor == nil && swappedIDs.isEmpty
            && transitionCoordinator == nil
        applySnapshot(animated: animatedApply)
        // The slack follows the content (#1799): a message arriving or deleted
        // in a short transcript slides the others in the apply's animation.
        // Older history is held by its anchor instead.
        syncBottomAnchor(movesOffset: anchor == nil, animated: animatedApply)
        if let anchor { hold(anchor) }
        guard case .content(let messages) = phase else { return }
        hasRenderedContent = true
        oldestID = messages.first?.id

        let newest = messages.last
        let newestChanged = newest?.id != newestID
        newestID = newest?.id
        // A delivered message taking its pending row's place is where the
        // stream already is: no second scroll (#719).
        let newestSwapped = newest.map { swappedIDs.contains($0.id) } ?? false
        swappedIDs = []
        if isFirstContent {
            pinToTail()
        } else if newestChanged, !newestSwapped, newest?.isMine == true || isNearBottom {
            if transitionCoordinator == nil { scrollToBottom(animated: true) } else { pinToTail() }
        }
    }

    private func applySnapshot(animated: Bool) {
        let previous = dataSource.snapshot()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        switch phase {
        case .loading:
            headerPolicy.daySections = false
            snapshot.appendSections([.main])
            // The gate's timing (#1770): no bones before its delay, none
            // once the wait ran past 10 s.
            guard skeletonGate.showsSkeleton else { break }
            // The last-known shape (#1774): as many rows as the thread had,
            // up to the fold (none for a thread that was empty), the day's
            // chip over them.
            let viewport = collectionView.bounds.height > 0 ? collectionView.bounds.height : view.bounds.height
            let count = SnapCommentsLayout.skeletonPlaceholderCount(
                viewportHeight: viewport, knownComments: rememberedMessageCount.map(Int64.init)
            )
            skeletonRowCount = count
            guard count > 0 else { break }
            snapshot.appendItems([.skeletonDay] + (0..<count).map(Item.skeleton))
        case .failed:
            headerPolicy.daySections = false
            snapshot.appendSections([.main])
        case .content(let messages) where messages.isEmpty:
            headerPolicy.daySections = false
            snapshot.appendSections([.main])
            snapshot.appendItems([.empty])
        case .content(let messages):
            headerPolicy.daySections = true
            let calendar = Calendar.current
            var currentDay: Date?
            for message in messages {
                let day = calendar.startOfDay(for: message.sentAt)
                if day != currentDay {
                    snapshot.appendSections([.day(day)])
                    currentDay = day
                }
                snapshot.appendItems([message.isSystem ? .system(message.id) : .message(message.id)], toSection: .day(day))
            }
            // Rows already on screen re-render in place when what they show
            // changed: a name, a face or a quote under a message whose
            // identity did not.
            //
            // ⚠️ ONLY THOSE (#725). Reconfiguring every surviving row on every
            // render re-ran each row's configure — avatars back to initials
            // until their picture hydrated, emotes restarted — so sending a
            // message blinked the whole transcript.
            let stale = snapshot.itemIdentifiers.filter { item in
                guard previous.indexOfItem(item) != nil, case .message(let id) = item,
                      let message = messagesByID[id] else { return false }
                return renderedRows[id] != rowSignature(for: message)
            }
            snapshot.reconfigureItems(stale)
        }
        debugLastApplyAnimated = animated
        dataSource.apply(snapshot, animatingDifferences: animated)
        // The skeleton sits where the messages will: at the tail (#1774).
        if case .loading = phase, !hasRenderedContent,
           snapshot.itemIdentifiers.contains(where: { if case .skeleton = $0 { true } else { false } }) {
            pinToTail()
        }
    }

    /// Whether the last render animated its differences. Tests.
    private(set) var debugLastApplyAnimated: Bool?
    /// Whether the day chip's bone leads the skeleton.
    var debugShowsSkeletonDay: Bool { dataSource.snapshot().itemIdentifiers.contains(.skeletonDay) }
    /// The skeleton rows in the list now.
    var debugSkeletonRowCount: Int {
        dataSource.snapshot().itemIdentifiers.filter { if case .skeleton = $0 { true } else { false } }.count
    }

    private func isAwaitingDelivery(_ message: ConversationThreadMessage) -> Bool {
        Self.showsDeliveryBesideName(message) && message.delivery != .sent
    }

    /// Whether the viewer's message shows its delivery beside "You": a text,
    /// and a voice message — its bubble keeps its play button, no loader
    /// over it (the owner, 2026-11-07). A photo or a clip shows it on its
    /// picture (`ThreadMediaView`).
    static func showsDeliveryBesideName(_ message: ConversationThreadMessage) -> Bool {
        message.isMine && (message.media == nil || message.media?.kind == .voice)
    }

    /// What delivery a row shows beside "You": a text's, sending or failed;
    /// a voice message's while sending only — its bubble says "Not sent.
    /// Tap to retry" itself.
    static func deliveryBesideName(of message: ConversationThreadMessage) -> ConversationThreadDelivery? {
        guard showsDeliveryBesideName(message) else { return nil }
        if message.media?.kind == .voice, message.delivery == .failed { return nil }
        return message.delivery
    }

    /// Whether `sent` is the delivered copy of the pending `pending`: the
    /// same words, and no media or the same voice take.
    static func isSameSend(_ pending: ConversationThreadMessage, _ sent: ConversationThreadMessage) -> Bool {
        guard pending.body == sent.body else { return false }
        switch (pending.media, sent.media) {
        case (nil, nil): return true
        case let (mine?, theirs?):
            return mine.kind == .voice && theirs.kind == .voice
                && abs((mine.duration ?? 0) - (theirs.duration ?? 0)) < 0.5
        default: return false
        }
    }

    /// What a message's row was last configured with, so a render can tell
    /// the rows that changed from the ones that did not (#725).
    private struct RowSignature: Equatable {
        let message: ConversationThreadMessage
        let author: ConversationThreadPerson
        let isGroupMember: Bool
    }

    private var renderedRows: [String: RowSignature] = [:]

    private func rowSignature(for message: ConversationThreadMessage) -> RowSignature {
        RowSignature(
            message: message,
            author: author(of: message),
            isGroupMember: group == nil && !message.isMine && peer.id == nil && !peer.name.isEmpty
        )
    }

    /// Who a row is signed by: the viewer, the peer — or, in a group, its
    /// own sender (#2214); a sender the group doesn't list (someone who
    /// left) has no name yet, and is signed "Member".
    private func author(of message: ConversationThreadMessage) -> ConversationThreadPerson {
        // A channel's posts are the channel's (#2215), the viewer's own too:
        // a stream under its name and photo, as Telegram's channels read.
        if let group, group.isChannel {
            return ConversationThreadPerson(id: nil, name: group.name, avatarURL: group.photoURL)
        }
        if message.isMine { return viewer }
        guard let group else { return peer }
        return group.members[message.senderID] ?? ConversationThreadPerson(id: message.senderID, name: "", avatarURL: nil)
    }

    /// What a row's sender is called: "You", their name — "Member" for a
    /// group sender not known (#2214), or any sender of a group drawn with
    /// no member list.
    static func authorName(
        of message: ConversationThreadMessage, author: ConversationThreadPerson, isGroup: Bool, peer: ConversationThreadPerson,
        isChannel: Bool = false
    ) -> String {
        // A channel signs every post itself (#2215).
        if isChannel { return author.name.isEmpty ? "Channel" : author.name }
        if message.isMine { return author.name.isEmpty ? "You" : author.name }
        if isGroup { return author.name.isEmpty ? "Member" : author.name }
        // A group drawn the old way: the header's name is every member's,
        // joined, and no per-member name exists — so a neutral label rather
        // than attributing each message to the whole group.
        if peer.id == nil, !peer.name.isEmpty { return "Member" }
        return author.name.isEmpty ? "Message" : author.name
    }

    #if DEBUG
    /// Every row configured, in order — what a render re-drew (#725). Tests.
    var debugConfiguredIDs: [String] = []
    #endif

    private func configure(_ cell: ThreadRowCell, messageID: String) {
        guard let message = messagesByID[messageID] else { return }
        renderedRows[messageID] = rowSignature(for: message)
        // A voice message is its bubble (#2104), under the row: no body, no
        // photo bubble, and its own sending, failed and retry.
        let voice = message.media?.kind == .voice
        let drawnMedia = voice ? nil : message.media
        let body = message.body
        #if DEBUG
        debugConfiguredIDs.append(messageID)
        #endif
        let writer = author(of: message)
        let name = Self.authorName(
            of: message, author: writer, isGroup: group != nil, peer: peer, isChannel: group?.isChannel == true
        )
        cell.row.configure(
            with: CommentDisplayModel(
                id: message.id,
                authorID: message.senderID,
                authorName: name,
                // A text of the viewer's on its way, or failed, has no time
                // yet: the spinner or the mark stands in its place (#725).
                metaText: isAwaitingDelivery(message) ? "" : Self.timeFormatter.string(from: message.sentAt),
                body: body,
                avatarURL: name == "Member" ? nil : writer.avatarURL
            ),
            imagePipeline: imagePipeline
        )
        cell.row.variant = .message
        // A group row's face opens its sender (#2214); a DM's, the peer.
        let sender = message.senderID
        if group?.isChannel == true {
            // A channel's face is the channel's: its info screen (#2215).
            cell.row.onAvatarTap = mode == .full ? { [weak self] in
                guard let self else { return }
                self.driver.didTapGroupInfo(from: self)
            } : nil
        } else {
            cell.row.onAvatarTap = message.isMine ? nil : group != nil
                ? { [weak self] in self?.driver.didTapMember(sender) }
                : { [weak self] in self?.driver.didTapIdentity() }
        }
        // A row tap answers it — the post's grammar. Nothing to answer in a peek.
        // While the keyboard is up, the tap retires it instead (see
        // `retireKeyboardOr`).
        // A channel's reader has nothing to answer with (#2215).
        cell.row.onReplyTap = mode == .full && group?.canPost != false ? { [weak self] in
            guard let self else { return }
            self.retireKeyboardOr { self.driver.beginReply(to: messageID) }
        } : nil
        if let quote = message.quote {
            cell.setQuote((quote.author, quote.snippet))
            cell.onQuoteTap = { [weak self] in self?.scrollToMessage(quote.messageID) }
        } else {
            cell.setQuote(nil)
        }
        cell.mediaView.configure(drawnMedia, delivery: message.delivery, pipeline: imagePipeline)
        // A text message of the viewer's shows whether it is on its way
        // (#719); a failed one is sent again by a tap.
        cell.loaderDelay = sendingLoaderDelay
        cell.setDelivery(
            Self.deliveryBesideName(of: message),
            time: Self.timeFormatter.string(from: message.sentAt)
        )
        if message.isMine, message.media == nil, message.delivery == .failed {
            cell.row.onReplyTap = { [weak self] in self?.driver.retry(messageID) }
        }
        if arrivingIDs.remove(messageID) != nil {
            arrivalStarts[messageID] = mediaTime()
            cell.playArrival()
        } else if deliveredIDs.remove(messageID) != nil {
            cell.playDelivered(revealing: Self.timeFormatter.string(from: message.sentAt))
        }
        configureVoice(cell.voiceView, for: message)
        cell.tucksVoice = voice
        cell.mediaView.onTap = drawnMedia == nil ? nil : { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.tapMedia(of: messageID, in: cell)
        }
    }

    /// Which of the viewer's messages just appeared on their way, and which
    /// just replaced their pending row (#719) — for `configure` to animate.
    private func noteSendTransitions(
        from before: [String: ConversationThreadMessage], to messages: [ConversationThreadMessage]
    ) {
        guard hasRenderedContent else { return }
        var goneSending = before.values.filter { $0.isMine && $0.delivery == .sending && messagesByID[$0.id] == nil }
        for message in messages where message.isMine && before[message.id] == nil {
            if message.delivery == .sending {
                arrivingIDs.insert(message.id)
            } else if message.delivery == .sent,
                      let index = goneSending.firstIndex(where: { Self.isSameSend($0, message) }) {
                goneSending.remove(at: index)
                if deliveredEarly.remove(message.id) == nil { deliveredIDs.insert(message.id) }
                swappedIDs.insert(message.id)
            }
        }
        arrivalStarts = arrivalStarts.filter { messagesByID[$0.key] != nil }
        renderedRows = renderedRows.filter { messagesByID[$0.key] != nil }
    }

    /// The pending rows a held-back phase delivers play their delivery now;
    /// true when one did.
    @discardableResult
    private func playEarlyDeliveries(in phase: ConversationThreadPhase) -> Bool {
        guard case .content(let messages) = phase else { return false }
        var played = false
        var pending = messagesByID.values.filter { Self.showsDeliveryBesideName($0) && $0.delivery == .sending }
        for message in messages where message.isMine && message.delivery == .sent && messagesByID[message.id] == nil
            && !deliveredEarly.contains(message.id) {
            guard let index = pending.firstIndex(where: { Self.isSameSend($0, message) && !messages.map(\.id).contains($0.id) })
            else { continue }
            let row = pending.remove(at: index)
            guard let path = dataSource.indexPath(for: .message(row.id)),
                  let cell = collectionView.cellForItem(at: path) as? ThreadRowCell else { continue }
            cell.playDelivered(revealing: Self.timeFormatter.string(from: message.sentAt), carryingSpinner: false)
            deliveredEarly.insert(message.id)
            played = true
        }
        return played
    }

    /// Delivered messages that took a pending row's place in this render.
    private var swappedIDs: Set<String> = []

    /// How long until the rise of a pending message this phase would retire
    /// lands; nil when nothing is mid-rise.
    private func riseStillLanding(before phase: ConversationThreadPhase) -> TimeInterval? {
        guard case .content(let messages) = phase, !arrivalStarts.isEmpty else { return nil }
        let ids = Set(messages.map(\.id))
        let now = mediaTime()
        let waits = arrivalStarts.compactMap { id, start -> TimeInterval? in
            guard !ids.contains(id) else { return nil }
            let left = ThreadRowCell.arrivalDuration - (now - start)
            return left > 0 ? left : nil
        }
        return waits.max()
    }

    private func adoptPeer(_ person: ConversationThreadPerson) {
        // KNOWN FIRST (#2049): what the app already holds for them — the
        // inbox row taught it their @handle and face — fills what the driver
        // has not read yet, so the pill comes in whole instead of filling in.
        let known = person.id.flatMap { entities?.knownIdentity(of: $0, stub: nil) }
        let person = ConversationThreadPerson(
            id: person.id,
            name: person.name.isEmpty ? known?.displayName ?? "" : person.name,
            avatarURL: person.avatarURL ?? known?.avatarURL,
            handle: person.handle ?? known?.handle.flatMap { $0.isEmpty ? nil : $0 }
        )
        peer = person
        // A group's header is the group's (#2214): the peer's name — its
        // members', joined — signs nothing and draws nothing.
        guard group == nil else {
            if hasRenderedContent { applySnapshot(animated: false) }
            return
        }
        // Named for VoiceOver, not drawn: no title in the bar.
        view.accessibilityLabel = person.name.isEmpty ? nil : "Conversation with \(person.name)"
        // The @handle under the name once known (#752), as a vertical post's
        // author pill wears it.
        let meta = person.handle.map { "@\($0)" } ?? ""
        // Only a change on a pill on screen and settled moves: what arrives
        // while the push brings it in is drawn as it is (`setPerson`).
        let settled = view.window != nil && transitionCoordinator == nil
        peerPill.setPerson(
            id: person.id, name: person.name, meta: meta, avatarURL: person.avatarURL, pipeline: imagePipeline,
            animated: settled
        )
        // Not on screen yet, or a push bringing it in: laid out now, so the
        // push only fades it in (`settleLayout`).
        if !settled { peerPill.settleLayout() }
        if person.id != relationAskedFor { startFromKnownRelation(of: person.id) }
        resolvePeerRelation()
        fitTrailingRun()
        if hasRenderedContent { applySnapshot(animated: false) }
    }

    /// The conversation is a group (#2214): the pill shows its picture — its
    /// photo, else its members' faces, else its initials, the inbox row's
    /// own (#2233) — its name and its subtitle, and a tap opens its info
    /// screen; each row is signed by its sender. A channel keeps its photo
    /// or initials. Nil: a DM after all — the peer's pill again.
    private func adoptGroup(_ newGroup: ConversationThreadGroup?) {
        let wasGroup = group != nil
        group = newGroup
        guard let newGroup else {
            peerPill.onGroupTapped = nil
            applyReaderStanding(nil)
            if mode == .full, toolbarShape != ToolbarShape() { configureToolbar() }
            if wasGroup { adoptPeer(peer) }
            return
        }
        view.accessibilityLabel = "Group conversation, \(newGroup.name)"
        let settled = view.window != nil && transitionCoordinator == nil
        peerPill.setFollowBadge(.none)
        // ⚠️ NEVER THE GROUP'S INITIALS ON A PERSON'S FACE (#2233): a
        // nameless group is named after its members, so "Sofía Reyes and Tom
        // Okafor" drew "SR" — read as Sofía's avatar. The group's picture
        // takes the face's place; the person's face under it loads nothing.
        let picture = newGroup.avatar
        peerPill.setPerson(
            id: nil, name: newGroup.name, meta: newGroup.subtitle, avatarURL: picture == nil ? newGroup.photoURL : nil,
            group: picture, pipeline: imagePipeline, animated: settled
        )
        if !settled { peerPill.settleLayout() }
        peerPill.onGroupTapped = mode == .full ? { [weak self] in
            guard let self else { return }
            self.driver.didTapGroupInfo(from: self)
        } : nil
        if newGroup.isChannel { view.accessibilityLabel = "Channel, \(newGroup.name)" }
        applyReaderStanding(newGroup.readerStanding)
        if mode == .full,
           toolbarShape != ToolbarShape(isChannel: newGroup.isChannel, isGroup: true, canPost: newGroup.canPost) {
            configureToolbar()
        }
        fitTrailingRun()
        if hasRenderedContent { applySnapshot(animated: false) }
    }

    // MARK: - A channel's reader (#2215)

    /// The composer for a viewer who posts; for one who doesn't, the reader
    /// bar in its place — or nothing, for a standing with nothing to take
    /// them in (#2236: a subscriber; #2217: a group closed to them). The
    /// composer stays laid out under the bar — hidden, its height still the
    /// stream's clearance — so the transcript doesn't move when one swaps
    /// for the other.
    ///
    /// ⚠️ A BARE FOOTER GIVES THE HEIGHT BACK (#2236): with neither composer
    /// nor bar, the inset, the band and the way back come down to the
    /// toolbar (`footerIsBare`). A change of standing on screen — Join to
    /// subscribed, Leave to Join — fades the bar and moves the clearance in
    /// one animation, so the messages ride it rather than jump.
    private func applyReaderStanding(_ standing: ConversationThreadReaderStanding?) {
        guard mode == .full else { return }
        readerActionInFlight = false
        readerStanding = standing
        let barWasShown = readerBarShown
        let composerWasShown = !composeBar.isHidden
        if let standing {
            composeBar.endEditing(true)
            driver.cancelReply()
            composeBar.isHidden = true
            let bar = readerBar ?? makeReaderBar()
            bar.setWorking(false)
            bar.configure(standing: standing)
            readerBarShown = !ConversationReaderBar.spec(for: standing).isEmpty
        } else {
            composeBar.isHidden = false
            readerBar?.setWorking(false)
            readerBarShown = false
        }
        refreshOverflowMenu()
        let footerChanged = barWasShown != readerBarShown || composerWasShown == composeBar.isHidden
        placeFooterFoot()
        let animated = footerChanged && view.window != nil && transitionCoordinator == nil && hasRenderedContent
            && !MotionPreference.reducesMotion
        showReaderBar(readerBarShown, animated: animated)
    }

    /// The bar in or out — faded, the clearance moving with it, when
    /// `animated`; at once otherwise.
    private func showReaderBar(_ shows: Bool, animated: Bool) {
        let bar = readerBar
        bar?.isUserInteractionEnabled = shows
        view.setNeedsLayout()
        guard animated else {
            bar?.isHidden = !shows
            bar?.alpha = 1
            return
        }
        if shows, let bar, bar.isHidden {
            bar.isHidden = false
            bar.alpha = 0
        }
        UIView.animate(
            springDuration: 0.4, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            bar?.alpha = shows ? 1 : 0
            // The band, the way back and the stream's clearance (laid out in
            // `viewDidLayoutSubviews`) in the same spring.
            self.view.layoutIfNeeded()
        } completion: { _ in
            // Shown again mid-fade: it stays.
            guard let bar, !self.readerBarShown else { return }
            bar.isHidden = true
            bar.alpha = 1
        }
    }

    private func makeReaderBar() -> ConversationReaderBar {
        let bar = ConversationReaderBar()
        bar.isHidden = true
        bar.onAction = { [weak self] action in self?.performReaderAction(action) }
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
            bar.bottomAnchor.constraint(equalTo: composeBar.bottomAnchor),
        ])
        readerBar = bar
        return bar
    }

    /// The bar's ways in (#2215, #2217).
    private func performReaderAction(_ action: ConversationReaderBar.Action) {
        switch action {
        case .join:
            guard !readerActionInFlight else { return }
            readerActionInFlight = true
            readerBar?.setWorking(true)
            driver.join()
        case .cancelRequest:
            withdrawRequest()
        case .follow:
            guard !readerActionInFlight else { return }
            readerActionInFlight = true
            readerBar?.setWorking(true)
            driver.follow()
        }
    }

    /// The ⋯ menu's ways out (#2236), each confirmed as the bar's were.
    private func performReaderExit(_ exit: ConversationReaderExit) {
        switch exit {
        case .leaveChannel:
            let name = group?.name ?? "this channel"
            confirmReader(
                title: "Leave \(name)?", message: "You won't see its posts any more.", button: "Leave"
            ) { [weak self] in
                // No in-flight hold: an owner's refusal (a notice) brings no
                // new standing to release it.
                guard let self else { return }
                self.driver.leave(from: self)
            }
        case .cancelRequest:
            withdrawRequest()
        case .unfollow:
            let name = group?.name ?? "this group"
            confirmReader(
                title: "Unfollow \(name)?", message: "It leaves your inbox. You can still read it while it's public.",
                button: "Unfollow"
            ) { [weak self] in
                guard let self, !self.readerActionInFlight else { return }
                self.readerActionInFlight = true
                self.driver.unfollow()
            }
        }
    }

    /// Requested's tap, or the menu's Cancel Request: asked first, then the
    /// bar's Requested shows the withdrawal on its way.
    private func withdrawRequest() {
        confirmReader(
            title: "Withdraw your request?", message: "You can ask again later.", button: "Withdraw"
        ) { [weak self] in
            guard let self, !self.readerActionInFlight else { return }
            self.readerActionInFlight = true
            self.readerBar?.setWorking(true)
            self.driver.cancelJoinRequest()
        }
    }

    private func confirmReader(title: String, message: String, button: String, _ confirmed: @escaping () -> Void) {
        #if DEBUG
        if let debugConfirmReader {
            debugConfirmReader(ReaderConfirmation(title: title, message: message, button: button, confirm: confirmed))
            return
        }
        #endif
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: button, style: .destructive) { _ in confirmed() })
        present(alert, animated: true)
    }

    #if DEBUG
    /// A confirmation the screen asks for (#2236). Tests.
    struct ReaderConfirmation {
        let title: String
        let message: String
        let button: String
        let confirm: () -> Void
    }

    /// Stands in for the alert (#2236): a hosted test never sees a modal
    /// complete. Tests.
    var debugConfirmReader: ((ReaderConfirmation) -> Void)?
    #endif

    private func adoptViewer(_ person: ConversationThreadPerson) {
        viewer = person
        composeBar.setViewerIdentity(
            ViewerIdentity(name: person.name, avatarURL: person.avatarURL), imagePipeline: imagePipeline
        )
        if hasRenderedContent { applySnapshot(animated: false) }
    }

    private func renderReply(_ draft: ConversationThreadReplyDraft?) {
        guard let draft else {
            composeBar.setReplyPlaceholder(name: nil)
            return
        }
        composeBar.setReplyPlaceholder(name: draft.author)
        composeBar.focusComposer()
    }

    // MARK: - The menu

    private func menu(at indexPath: IndexPath) -> UIMenu? {
        guard case .message(let id) = dataSource.itemIdentifier(for: indexPath),
              let message = messagesByID[id] else { return nil }
        let reply = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) {
            [weak self] _ in self?.driver.beginReply(to: id)
        }
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = message.body
            self?.confirmCopied()
        }
        let select = UIAction(title: "Select Text", image: UIImage(systemName: "text.magnifyingglass")) {
            [weak self] _ in self?.selectText(of: id)
        }
        let forward = UIAction(title: "Forward", image: UIImage(systemName: "arrowshape.turn.up.right")) {
            [weak self] _ in self?.driver.forward(id)
        }
        let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) {
            [weak self] _ in self?.confirmDelete(id)
        }
        // A channel's reader reads (#2215): no Reply, and nothing of theirs
        // to delete.
        if group?.canPost == false {
            return message.media?.kind == .voice ? nil : UIMenu(children: [copy, select, forward])
        }
        // A voice message has no text to copy or select, and forwarding it
        // waits for a later issue (#2103): Reply and Delete.
        if message.media?.kind == .voice {
            return UIMenu(children: [reply, UIMenu(options: .displayInline, children: [delete])])
        }
        return UIMenu(children: [reply, copy, select, forward, UIMenu(options: .displayInline, children: [delete])])
    }

    private func selectText(of messageID: String) {
        guard let indexPath = dataSource.indexPath(for: .message(messageID)) else { return }
        contextMenu.beginTextSelection(at: indexPath)
    }

    /// Deleting asks first, once the context menu has finished leaving —
    /// its own dismissal, not a guessed run-loop turn (see
    /// `ThreadRowContextMenu.afterMenuDismissal`).
    private func confirmDelete(_ messageID: String) {
        contextMenu.afterMenuDismissal { [weak self] in
            guard let self, self.presentedViewController == nil else { return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Delete Message", style: .destructive) { [weak self] _ in
                self?.deleteWithDeparture(messageID)
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = self.view
            sheet.popoverPresentationController?.sourceRect = CGRect(
                x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0
            )
            self.present(sheet, animated: true)
        }
    }

    /// The row leaves with its departure (#920) — a message sinks back the way
    /// it rose — and the delete lands once it is gone. A row not on screen has
    /// nothing to play: it is deleted at once.
    ///
    /// Deleting a message is local and cannot fail (the transcript hides it),
    /// so the row is never left invisible on a delete that did not happen; and
    /// a recycled cell is put back at full ink by `prepareForReuse`. Internal
    /// for tests.
    func deleteWithDeparture(_ messageID: String) {
        guard let indexPath = dataSource.indexPath(for: .message(messageID)),
              let cell = collectionView.cellForItem(at: indexPath) as? ThreadRowCell else {
            driver.delete(messageID)
            return
        }
        cell.playDeparture { [weak self] in self?.driver.delete(messageID) }
    }

    // MARK: - Scrolling

    /// The topmost message on screen and its distance from the top of the
    /// viewport — when `phase` brings older history above the oldest message
    /// shown, and only then.
    private func olderHistoryAnchor(for phase: ConversationThreadPhase) -> (id: String, offset: CGFloat)? {
        guard hasRenderedContent, case .content(let messages) = phase,
              let oldestID, messages.first?.id != oldestID,
              messages.contains(where: { $0.id == oldestID })
        else { return nil }
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard case .message(let id) = dataSource.itemIdentifier(for: indexPath),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            else { continue }
            return (id, frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    /// Puts the anchored message back where it was on screen, once the rows
    /// above it exist.
    private func hold(_ anchor: (id: String, offset: CGFloat)) {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: .message(anchor.id)),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
        else { return }
        collectionView.contentOffset.y = frame.minY - anchor.offset
    }

    /// ⚠️ THE TAIL HOLDS WHILE THE ROWS SIZE THEMSELVES (the owner's device,
    /// 2026-11-02). A long conversation is pinned on estimated heights; its
    /// rows then size for real as they come on screen — under the push — and
    /// each one moved the content under a fixed offset: the conversation came
    /// in high and slid down to its place. A short one, all on screen at the
    /// pin, never moved. Until the reader scrolls (or the screen scrolls to a
    /// day or a quote), every change of the content's height keeps the
    /// newest message where it rests, at once.
    private var holdsTail = false
    /// Whether the stream still holds its tail for the screen's arrival. Tests.
    var debugHoldsTail: Bool { holdsTail }
    /// Once the screen has come in: the tail is held for its arrival only —
    /// a message landing while the reader reads keeps its own animated scroll.
    private var hasAppeared = false
    /// Where the reader stood — the offset and the content height then —
    /// and a bottom inset deep enough for any footer, while a finger-driven
    /// pop is under way and until a cancelled one has the screen back.
    ///
    /// ⚠️ THE END MUST NEVER COME ABOVE THE READER (the owner's device,
    /// 2026-11-06, filmed and logged, long conversations only). A cancelled
    /// pop sets the footer hidden for a moment before it comes back: the safe
    /// area fell from 86 to 34, the end of a transcript resting at its tail
    /// rose 52 pt above the offset, and UIKit clamped the offset at once
    /// (326 → 274); putting it back ran inside the footer's return animation,
    /// so the list visibly slid. Holding the inset as deep as the footer's
    /// absence would need, from the start, keeps the end where it was: UIKit
    /// never clamps, nothing moves.
    ///
    /// ⚠️ ONLY A TRANSCRIPT WITH NO SLACK (filmed the same day): a short one
    /// wears its slack above, measured against the bottom inset — the deep
    /// inset shrank it and the messages rose. It never reaches its end, and
    /// is left alone.
    private var heldPlace: HeldPlace?

    private struct HeldPlace: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var inset: CGFloat
    }
    private var contentSizeObservation: NSKeyValueObservation?

    private func observeContentSize() {
        contentSizeObservation = collectionView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue?.height != change.newValue?.height else { return }
            MainActor.assumeIsolated { self?.keepTail() }
        }
    }

    private func keepTail() {
        guard holdsTail, hasRenderedContent, !owesTailPin, !collectionView.isTracking,
              !collectionView.isDecelerating else { return }
        let insets = collectionView.adjustedContentInset
        let tail = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        guard abs(collectionView.contentOffset.y - tail) > 0.5 else { return }
        UIView.performWithoutAnimation { collectionView.contentOffset.y = tail }
    }

    private var isNearBottom: Bool {
        let insets = collectionView.adjustedContentInset
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - insets.bottom
        return visibleBottom >= collectionView.contentSize.height - 120
    }

    /// Keeps the deep inset and the reader where they stood (`heldPlace`),
    /// moved only by what the content grew meanwhile.
    private func holdPlace() {
        guard let held = heldPlace else { return }
        if abs(collectionView.contentInset.bottom - held.inset) > 0.25 {
            collectionView.contentInset.bottom = held.inset
            collectionView.verticalScrollIndicatorInsets.bottom = held.inset
        }
        let offset = held.offset + collectionView.contentSize.height - held.contentHeight
        if abs(collectionView.contentOffset.y - offset) > 0.25 { collectionView.contentOffset.y = offset }
    }

    /// Ends the hold: the inset back to the composer's, the offset left
    /// alone — the reader is where they were, and the end below them.
    private func releaseHeldPlace() {
        heldPlace = nil
        guard let inset = restingBottomInset else { return }
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
    }

    /// The stream's bottom inset over a bare footer (#2236), on top of the
    /// safe area the toolbar inflates.
    static let bareBottomInset: CGFloat = SnapActionColumn.bottomBreath + Spacing.sm

    /// The bottom inset the composer asks for: clear of it, a little air.
    private var restingBottomInset: CGFloat? {
        // Neither composer nor bar (#2236): clear of the toolbar alone, a
        // breath over it as a post's bottom block stands.
        if footerIsBare {
            guard view.bounds.height > 0 else { return nil }
            return Self.bareBottomInset
        }
        // A channel's reader (#2215): clear of the bar in the composer's place.
        if readerBarShown, let readerBar, readerBar.bounds.height > 0 {
            return max(0, view.bounds.height - min(readerBar.frame.minY, composeBar.occupiedMinY)
                - view.safeAreaInsets.bottom) + Spacing.sm
        }
        guard composeBar.bounds.height > 0 else { return nil }
        // The bar's top at rest, the risen input row's while the keyboard
        // holds it above the bar (the pin stays down there, under it).
        return max(0, view.bounds.height - composeBar.occupiedMinY - view.safeAreaInsets.bottom) + Spacing.sm
    }

    private func scrollToBottom(animated: Bool) {
        collectionView.layoutIfNeeded()
        let insets = collectionView.adjustedContentInset
        let bottom = collectionView.contentSize.height + insets.bottom - collectionView.bounds.height
        collectionView.setContentOffset(CGPoint(x: 0, y: max(-insets.top, bottom)), animated: animated)
    }

    /// Lands the first content on its newest message, exactly, before the
    /// frame is committed.
    ///
    /// ⚠️ **NOT "ONCE NOW AND ONCE NEXT TURN".** Estimated heights refine as
    /// the rows at the tail realise, so the first pass lands short — and the
    /// second pass used to run a run-loop turn later, after the short frame
    /// had been committed: content arriving on screen showed one frame at the
    /// wrong offset and then jumped, and on a long transcript the second pass
    /// realised new rows that refined AGAIN, stopping short with nothing left
    /// to retry. Here each pass lays out at the offset it just set, and it
    /// repeats until the content height stops moving (bounded).
    ///
    /// ⚠️ **AND NOT BEFORE THE COMPOSER'S CLEARANCE EXISTS.** The first resting
    /// bottom inset is deliberately not treated as travel (`syncBottomClearance`),
    /// so a tail pinned before it lands a composer's height short — which the
    /// old next-turn pass was also silently absorbing. A stream with no height,
    /// or a full screen whose clearance is not established yet, owes the pin
    /// to its layout pass, which pays it right after the clearance.
    private func pinToTail() {
        guard collectionView.bounds.height > 0, mode != .full || hasEstablishedClearance else {
            owesTailPin = true
            return
        }
        owesTailPin = false
        if !hasAppeared { holdsTail = true }
        // Never animated, whatever block it runs in: the tail is where the
        // conversation IS, not somewhere it travels to.
        UIView.performWithoutAnimation {
            for _ in 0..<4 {
                let heightBefore = collectionView.contentSize.height
                scrollToBottom(animated: false)
                collectionView.layoutIfNeeded()
                if abs(collectionView.contentSize.height - heightBefore) < 0.5 { break }
            }
        }
    }

    /// Puts the opening's offset at the tail its ESTIMATED layout gives,
    /// before the first layout realises any row (#2121).
    ///
    /// The first layout used to run at the top — the bottom anchor's — and
    /// realised the transcript's first screen, then the tail pin scrolled
    /// down and realised its last: every row of an 18-message conversation
    /// was built and measured (~2.3 ms each on the simulator) for the ~9 on
    /// screen. Aimed here, the first layout realises the tail's rows only,
    /// and `pinToTail` refines them exactly as before — the screen settles
    /// where it always did, in the same pass, before the frame is committed.
    private func aimAtEstimatedTail() {
        guard let section = (0..<collectionView.numberOfSections).last(where: {
            collectionView.numberOfItems(inSection: $0) > 0
        }) else { return }
        let last = IndexPath(item: collectionView.numberOfItems(inSection: section) - 1, section: section)
        UIView.performWithoutAnimation {
            collectionView.scrollToItem(at: last, at: .bottom, animated: false)
        }
    }

    /// Brings a quoted message to the middle of the stream and flashes it —
    /// when the scroll ends, or at once if there is nothing to scroll.
    ///
    /// ⚠️ **NOT A 0.5 s FALLBACK.** "Already on screen, no scroll will end"
    /// used to be covered by a timer that fired whatever happened: a second
    /// quote tapped inside it had its flash taken by the first timer mid-scroll
    /// (on a cell still moving, or on none — and then lost), and a quote that
    /// was already centred flashed half a second late. The target offset is
    /// computed here, so the method knows which of the two cases it is in.
    private func scrollToMessage(_ messageID: String) {
        guard let indexPath = dataSource.indexPath(for: .message(messageID)) else { return }
        holdsTail = false
        pendingFlashID = messageID
        collectionView.layoutIfNeeded()
        guard let row = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let insets = collectionView.adjustedContentInset
        let visible = collectionView.bounds.height - insets.top - insets.bottom
        let maxOffset = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        let target = min(max(row.midY - insets.top - visible / 2, -insets.top), maxOffset)
        guard abs(target - collectionView.contentOffset.y) >= 1 else { return flashPending() }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: true)
    }

    private func flashPending() {
        guard let id = pendingFlashID, let indexPath = dataSource.indexPath(for: .message(id)) else { return }
        pendingFlashID = nil
        (collectionView.cellForItem(at: indexPath) as? ThreadRowCell)?.flash()
    }

    /// A short transcript STARTS FROM THE BOTTOM, as in a messaging app
    /// (#1799; the default since #1923): the room above it — the
    /// slack, `StreamBottomAnchor` — is worn in the top inset, so two
    /// messages rest just above the composer. A transcript taller than the
    /// stream has no slack and is exactly as before; growing past it, the
    /// slack shrinks to 0 with no jump.
    ///
    /// Measured after layout: while there is slack every row is realised, so
    /// the content height is exact. The empty state (full height, centred) is
    /// left alone. Not before the composer's clearance exists: the first
    /// resting bottom inset is what the slack is measured against.
    ///
    /// `movesOffset`: the stream rests at its tail (with slack, that is the
    /// whole transcript just above the composer). Off for older history, which
    /// its anchor holds (`hold`), and under a finger.
    private func syncBottomAnchor(movesOffset: Bool = true, animated: Bool = false) {
        guard anchorsShortStream, mode == .full, hasEstablishedClearance, collectionView.bounds.height > 0 else { return }
        collectionView.layoutIfNeeded()
        var showsEmpty = false
        if case .content(let messages) = phase { showsEmpty = messages.isEmpty }
        let slack = showsEmpty ? 0 : StreamBottomAnchor.slack(for: collectionView, wearing: bottomAnchorSlack)
        let previous = bottomAnchorSlack
        guard abs(slack - previous) > 0.5 else { return }
        bottomAnchorSlack = slack
        let apply = {
            self.collectionView.contentInset.top = SnapCommentsLayout.streamTopBreath + slack
            guard movesOffset, slack > 0 || previous > 0 else { return }
            let insets = self.collectionView.adjustedContentInset
            let tail = self.collectionView.contentSize.height + insets.bottom - self.collectionView.bounds.height
            self.collectionView.contentOffset.y = max(-insets.top, tail)
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

    /// Keeps the newest message clear of the composer, and carries the reader
    /// with the composer when it moves.
    ///
    /// Measured from the composer's REAL frame — the keyboard, a growing
    /// field and the footer all move it, and arithmetic on any one of them
    /// double-counts another. The offset is read BEFORE the inset is written,
    /// because writing the inset makes UIKit clamp the offset at once, and
    /// adding the travel on top of an already-clamped value throws the list
    /// to the top of a short transcript.
    private func syncBottomClearance() {
        guard let inset = restingBottomInset else { return }
        if heldPlace != nil, hasEstablishedClearance, hasRenderedContent {
            return holdPlace()
        }
        let delta = inset - collectionView.contentInset.bottom
        guard abs(delta) > 0.5 else { return }
        let offsetBefore = collectionView.contentOffset.y
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
        // The first resting inset is not travel, and a finger scrubbing the
        // keyboard down owns the offset itself.
        guard hasEstablishedClearance, hasRenderedContent, !collectionView.isTracking else {
            hasEstablishedClearance = true
            return
        }
        let insets = collectionView.adjustedContentInset
        let maxOffset = max(-insets.top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        collectionView.contentOffset.y = min(max(offsetBefore + delta, -insets.top), maxOffset)
    }

    // MARK: - Bars

    /// The peer pill's share of its bar: on the footer, what the pin, the
    /// bell and ⋯ leave; in a preview's nav bar, the bar less its margins
    /// and the back button. Measured, and applied before the bar first lays
    /// the run out (see `viewWillAppear`).
    /// Whether the peer pill is the toolbar's leading item (#671): on the full
    /// thread, which has a toolbar; a preview keeps it in the bar.
    private var pillRidesToolbar: Bool { mode == .full }

    private func fitTrailingRun() {
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }
        let itemPadding: CGFloat = 18
        if pillRidesToolbar {
            // The toolbar's leading slot (#671): what the footer's stock items
            // leave — the pin and the bell in one platter (#2344), as the
            // post's [☆ ⇄]; the pin alone on a draft — and ⋯, as the post's
            // footer measures them, at this text size (#1679). A long name
            // truncates in the pill; the bubbles never fold into `•••`.
            let icon = SnapBarPillWidths.toolbarIcon(for: traitCollection)
            let reserve = muted == nil
                ? SnapBarPillWidths.toolbarReserve(icon: icon, lone: 1)
                : SnapBarPillWidths.toolbarReserve(icon: icon)
            peerPill.setWidthBudget(bar - reserve)
            return
        }
        peerPill.setWidthBudget(bar - 16 * 2 - (36 + itemPadding) - itemPadding)
    }

    // MARK: - Misc

    /// What an empty conversation says: one copy for the row and for its
    /// measurement.
    private static let emptyPageCopy = PostDetailViewController.EmptyPageCopy(
        symbol: "bubble.left.and.bubble.right",
        title: "No messages yet",
        subtitle: "Say hi 👋"
    )

    private func emptyPageHeight() -> CGFloat {
        let insets = collectionView.adjustedContentInset
        let height = collectionView.bounds.height > 0 ? collectionView.bounds.height : view.bounds.height
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        let copy = Self.emptyPageCopy
        return SnapCommentsLayout.emptyPageHeight(
            // Nil before layout: no geometry to fit yet.
            availableHeight: height > 0 ? height - insets.top - insets.bottom : nil,
            // The section's side insets, which the row's width is less.
            blockHeight: CommentsEmptyPageCell.blockHeight(
                symbolName: copy.symbol,
                title: copy.title,
                subtitle: copy.subtitle,
                width: width - Spacing.lg * 2,
                contentSizeCategory: traitCollection.preferredContentSizeCategory
            )
        )
    }

    /// When a notice can show over what this screen presents.
    enum NoticeTiming: Equatable {
        /// Nothing covers the screen.
        case now
        /// A screen on its way out — the media picker, closing as its photos
        /// start sending: once it has gone.
        case afterDismissal
        /// Something the viewer is still using: not over it.
        case never
    }

    static func noticeTiming(over presented: UIViewController?) -> NoticeTiming {
        guard let presented else { return .now }
        return presented.isBeingDismissed ? .afterDismissal : .never
    }

    /// ⚠️ **THE PICKER IS STILL CLOSING WHEN A SEND CAN FAIL (#794).** The
    /// driver dismisses it and sends at once, so an upload that fails fast
    /// (offline) reported while the picker was still presented, and the
    /// "You’re offline" alert was dropped. A notice over a screen on its way
    /// out waits for that dismissal to complete; a cancelled one drops it.
    private func presentNotice(_ title: String, _ message: String) {
        switch Self.noticeTiming(over: presentedViewController) {
        case .now:
            break
        case .afterDismissal:
            guard let coordinator = presentedViewController?.transitionCoordinator else { return }
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled else { return }
                self?.presentNotice(title, message)
            }
            return
        case .never:
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func handleStreamTap() {
        view.endEditing(true)
    }

    /// A tap on a message's BODY while the keyboard is up retires the
    /// keyboard instead of arming a reply — the post's rule (see
    /// `PostDetailViewController.retireKeyboardOr`): the row's reply tap is
    /// nearer the touch and prevents the stream's, so the row must say it.
    /// The quote strip and the avatar keep their own taps.
    private func retireKeyboardOr(_ work: () -> Void) {
        if composeBar.isEditingDraft {
            view.endEditing(true)
        } else {
            work()
        }
    }
}

extension ConversationThreadViewController: UICollectionViewDelegate {
    /// Paging, backwards (#600): the reader scrolling within a screen of the
    /// top asks for the history before it. Only the reader's own scroll asks —
    /// the screen's programmatic moves (the tail pin, a quote jump) never do —
    /// and never in a peek.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncDayItem()
        // Only the reader's own scroll shows the way back; any move hides it
        // once the newest message is near again (#1929).
        syncScrollAway(userScroll: scrollView.isTracking || scrollView.isDecelerating)
        guard mode == .full, hasRenderedContent, scrollView.isTracking || scrollView.isDecelerating,
              scrollView.contentOffset.y + scrollView.adjustedContentInset.top < scrollView.bounds.height
        else { return }
        driver.loadOlder()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The reader's own scroll: the conversation no longer holds its tail.
        holdsTail = false
        contextMenu.endTextSelection()
        // The reader took over: a flash landing after their own scroll would
        // point at something they have moved away from.
        pendingFlashID = nil
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        flashPending()
    }
}

extension ConversationThreadViewController {
    /// The correspondent pill's lines that show, top to bottom (#752). Tests.
    var debugPeerPillLines: [String] {
        func labels(in view: UIView) -> [UILabel] {
            if view is MonogramAvatarView { return [] } // the face's initials
            return (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        return labels(in: peerPill)
            .filter { !$0.isHidden && !($0.text ?? "").isEmpty }
            .sorted { $0.convert($0.bounds, to: peerPill).minY < $1.convert($1.bounds, to: peerPill).minY }
            .compactMap(\.text)
    }
}

// MARK: - The correspondent's relation (#752)

extension ConversationThreadViewController {
    /// Asks the graph where the viewer stands with the correspondent: once
    /// per peer, or again with `refresh`. The answer on show keeps drawing
    /// until the new one lands.
    func resolvePeerRelation(refresh: Bool = false) {
        guard mode == .full, socialGraph != nil, let followRelations, let id = peer.id,
              refresh || relationAskedFor != id, !followInFlight else { return }
        relationAskedFor = id
        relationGeneration += 1
        let generation = relationGeneration
        Task { [weak self] in
            guard let relation = try? await followRelations.followRelation(to: id) else { return }
            guard let self, self.peer.id == id, !self.followInFlight, self.relationGeneration == generation else { return }
            // The graph's answer, for every surface showing them (#2049).
            self.entities?.setRelation(relation, for: id)
            self.setPeerRelation(relation)
        }
    }

    /// A new correspondent: the relation already known for them, drawn at
    /// once, from the first frame — no wait for the read, which then only
    /// confirms it (#2049, the owner 2026-11-02: the inbox row knew it). And
    /// from now on, every change to it in the store: a follow made from a
    /// profile card over the thread, from their profile, anywhere.
    private func startFromKnownRelation(of id: ProfileID?) {
        let known = id.flatMap { entities?.relation(to: $0) }
        peerRelation = known
        peerPill.setFollowBadge(badge(for: known), animated: false)
        peerObservation?.cancel()
        peerObservation = id.flatMap { id in
            entities?.observeProfile(id) { [weak self] _ in self?.knownRelationDidChange(for: id) }
        }
    }

    /// The store's relation for the correspondent moved — a follow, a
    /// request, an unfollow made elsewhere, or a viewer change. The thread's
    /// own follow in flight draws its own answer.
    private func knownRelationDidChange(for id: ProfileID) {
        guard peer.id == id, !followInFlight, let entities else { return }
        let known = entities.relation(to: id)
        guard known != peerRelation else { return }
        relationGeneration += 1
        setPeerRelation(known)
    }

    /// Either way the badge's symbol is replaced and nothing else moves
    /// (#925), as on a post.
    ///
    /// - Parameter tapped: the viewer's own follow (or its refusal), drawn at
    ///   once. Anything else is a value that LANDED — a read answering, a new
    ///   peer — and waits out a push or pop under way (#889).
    private func setPeerRelation(_ relation: FollowRelation?, tapped: Bool = false) {
        peerRelation = relation
        if tapped {
            peerPill.setFollowBadge(badge(for: relation), animated: view.window != nil)
        } else {
            drawLandedRelation()
        }
        fitTrailingRun()
    }

    /// The peer's mark: the skeleton's badge while a relation that will be
    /// read is not known yet (#2098), never nothing; none where no read
    /// comes (a group, no graph).
    private func badge(for relation: FollowRelation?) -> SnapAuthorIdentityView.FollowBadge {
        if let relation { return SnapAuthorIdentityView.FollowBadge(relation) }
        return readsPeerRelation ? .loading : .none
    }

    /// Whether the correspondent's relation is read at all — what
    /// `resolvePeerRelation` asks.
    private var readsPeerRelation: Bool {
        mode == .full && socialGraph != nil && followRelations != nil && peer.id != nil
    }

    /// Draws `peerRelation` on the pill's badge — once the push or pop under
    /// way has landed (#889): the transition is UIKit's alone (owner,
    /// 2026-10-11), and a change drawn inside it is a change nobody sees.
    /// Off screen, or with no transition, at once.
    private func drawLandedRelation() {
        guard !landedRelationScheduled else { return }
        if view.window != nil, let coordinator = transitionCoordinator {
            landedRelationScheduled = true
            let scheduled = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                // One turn later: the bar settles its landing first.
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.landedRelationScheduled = false
                    self.peerPill.setFollowBadge(
                        self.badge(for: self.peerRelation), animated: self.view.window != nil
                    )
                }
            }
            if scheduled { return }
            // The coordinator took nothing: never leave the flag stuck.
            landedRelationScheduled = false
        }
        peerPill.setFollowBadge(badge(for: peerRelation), animated: view.window != nil)
    }

    /// The "+": follows the correspondent, optimistically, as the feed's
    /// author pill does; a refusal puts the relation back.
    func followPeer(_ id: ProfileID) {
        MemberGates.perform(.follow(handle: peer.handle), from: self) { [weak self] in
            self?.commitFollow(id)
        }
    }

    private func commitFollow(_ id: ProfileID) {
        guard let socialGraph, peer.id == id, !followInFlight, let before = peerRelation,
              SnapAuthorIdentityView.FollowBadge(before) == .follow else { return }
        followInFlight = true
        relationGeneration += 1
        // Named now: the peer can change before the graph answers.
        let message = PlusFollow.failureMessage(handle: peer.handle, name: peer.name)
        // The inbox's "+" follows the same way (#2049): one seam, `PlusFollow`.
        PlusFollow.commit(id, from: before, through: socialGraph, apply: { [weak self] relation in
            guard let self else { return }
            // Every surface showing them follows the tap (#2049).
            self.entities?.setRelation(relation, for: id)
            guard self.peer.id == id else { return }
            self.setPeerRelation(relation, tapped: true)
        }, completion: { [weak self] failed in
            guard let self else { return }
            self.followInFlight = false
            // Said either way (#802), as the mute's is.
            if failed { Feedback.failure(message, from: self) }
            // The peer changed mid-follow: its relation was never asked.
            if self.peer.id != id { self.resolvePeerRelation() }
        })
    }

    /// The pill's relation badge. Tests.
    var debugPeerFollowBadge: SnapAuthorIdentityView.FollowBadge { peerPill.followBadge }
    #if DEBUG
    /// The name a message's row is signed with (#2214). Tests.
    func debugAuthorName(of messageID: String) -> String? {
        messagesByID[messageID].map {
            Self.authorName(of: $0, author: author(of: $0), isGroup: group != nil, peer: peer, isChannel: group?.isChannel == true)
        }
    }
    /// Whether a message is drawn as a system line (#2214). Tests.
    func debugIsSystemLine(_ messageID: String) -> Bool {
        dataSource.indexPath(for: .system(messageID)) != nil
    }
    /// What the header pill shows (#2214). Tests.
    var debugPillName: String { peerPill.debugName }
    /// The group the pill draws in its face's place (#2233). Tests.
    var debugPillGroupAvatar: GroupAvatarContent? { peerPill.debugGroupAvatar }
    /// The pill's group picture view (#2233). Tests.
    var debugPillGroupAvatarView: GroupAvatarView? { peerPill.debugGroupAvatarView }
    /// Whether the composer shows — a channel's reader gets the bar (#2215). Tests.
    var debugShowsComposer: Bool { !composeBar.isHidden }
    /// The reader bar's standing while it shows (#2215). Tests.
    var debugReaderStanding: ConversationThreadReaderStanding? { readerStanding }
    /// Whether the reader bar shows — a group closed to the viewer and a
    /// channel's subscriber get none (#2217, #2236). Tests.
    var debugShowsReaderBar: Bool { readerBarShown }
    /// Whether the footer is bare, the band and the way back on the toolbar (#2236). Tests.
    var debugFooterIsBare: Bool { footerIsBare }
    /// The stream's bottom inset (#2236). Tests.
    var debugBottomInset: CGFloat { collectionView.contentInset.bottom }
    /// A reader bar tap, as the bar sends it (#2217). Tests.
    func debugReaderAction(_ action: ConversationReaderBar.Action) { performReaderAction(action) }
    /// The ⋯ menu's way out, picked (#2236). Tests.
    func debugReaderExit(_ exit: ConversationReaderExit) { performReaderExit(exit) }
    /// The footer's ⋯ menu (#2236). Tests.
    var debugOverflowMenu: UIMenu? { moreItem?.menu }
    /// The ⋯ menu's titles, flattened (#2236). Tests.
    var debugOverflowMenuTitles: [String] {
        func titles(_ element: UIMenuElement) -> [String] {
            if let menu = element as? UIMenu { return menu.children.flatMap(titles) }
            return [element.title]
        }
        return debugOverflowMenu.map(titles) ?? []
    }
    /// Taps the header pill (#2214). Tests.
    func debugTapPill() { peerPill.debugTap() }
    #endif

    #if DEBUG
    /// The long-press menu's titles for a message, flattened. Tests.
    func debugMenuTitles(for messageID: String) -> [String] {
        guard let indexPath = dataSource.indexPath(for: .message(messageID)),
              let menu = menu(at: indexPath) else { return [] }
        func titles(_ element: UIMenuElement) -> [String] {
            if let menu = element as? UIMenu { return menu.children.flatMap(titles) }
            return [element.title]
        }
        return menu.children.flatMap(titles)
    }
    #endif
}

// MARK: - The swipe chain (#1525)

extension ConversationThreadViewController: SwipeStageHosting {
    /// ⚠️ A LEFTWARD SWIPE PUSHES THE PEER'S PROFILE (#1525, the owner
    /// 2026-10-21), following the finger — anywhere on the thread but where a
    /// view owns horizontal drags or text selection: the composer (its text
    /// view, its emote strip) and any horizontal strip in the stream. One
    /// peer only: a group has no push stage.
    func swipeStage(for direction: SwipeDirection, at origin: CGPoint) -> SwipeStage? {
        guard direction == .leftward, !Self.ownsHorizontalDrag(at: origin, in: view, composer: composeBar),
              let profile = driver.peerProfileDestination() else { return nil }
        return .push { profile }
    }

    var swipeNavigationController: UINavigationController? { navigationController }

    func swipePushDidEnd(committed: Bool) {}

    /// Whether the touch at `point` lands on something that keeps its own
    /// horizontal drag: the composer, a text view (selection), a scroll view
    /// that scrolls sideways, or a voice message — its waveform scrubs and
    /// its play button takes the tap, before the screen's swipe (the owner's
    /// device check, 2026-11-06).
    static func ownsHorizontalDrag(at point: CGPoint, in view: UIView, composer: UIView) -> Bool {
        guard let hit = view.hitTest(point, with: nil) else { return false }
        for current in sequence(first: hit, next: { $0.superview }) {
            if current === composer || current is UITextView { return true }
            if let voice = current as? ThreadVoiceView, voice.keepsDrag(at: current.convert(point, from: view)) { return true }
            if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return true }
            if current === view { break }
        }
        return false
    }
}

// MARK: - How it is left (#1144)

extension ConversationThreadViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}

// MARK: - Voice messages (#2104)

extension ConversationThreadViewController {
    /// The bubble's state for `message`: what the one player says when it is
    /// the one it speaks for, where it was left otherwise.
    private func voiceState(for message: ConversationThreadMessage) -> ThreadVoiceView.State? {
        guard let media = message.media, media.kind == .voice else { return nil }
        var state = ThreadVoiceView.State()
        state.delivery = message.isMine ? .init(message.delivery) : .sent
        state.levels = media.waveform
        state.duration = media.duration ?? (voicePlayer.messageID == message.id ? voicePlayer.duration : nil) ?? 0
        state.unplayed = !message.isMine && !voicePlayed.isPlayed(message.id)
        state.speedLabel = voicePlayer.speed.label
        if voicePlayer.messageID == message.id {
            let progress = voicePlayer.progress ?? voicePositions[message.id] ?? 0
            state.playback = switch voicePlayer.state {
            case .loading: .loading
            case .playing: .playing(progress: progress)
            case .paused: progress > 0 ? .paused(progress: progress) : .rest
            case .failed: .failed
            case .idle, .ended: .rest
            }
        } else if let position = voicePositions[message.id], position > 0 {
            state.playback = .paused(progress: position)
        }
        return state
    }

    private func configureVoice(_ view: ThreadVoiceView, for message: ConversationThreadMessage) {
        let state = voiceState(for: message)
        let sender = message.isMine ? "" : author(of: message).name
        view.configure(state, senderName: sender.isEmpty ? nil : sender)
        guard state != nil else { return }
        let id = message.id
        view.onPlayTap = { [weak self] in self?.toggleVoice(id) }
        view.onSeek = { [weak self] fraction, scrubbing in self?.seekVoice(id, to: fraction, scrubbing: scrubbing) }
        view.onSpeedTap = { [weak self] in
            guard let self else { return }
            voicePlayer.setSpeed(voicePlayer.speed.next)
        }
        view.onRetry = { [weak self] in self?.driver.retry(id) }
    }

    /// Where the message's audio is: the viewer's own take while it is on
    /// its way, the device's copy, else its delivery.
    private func voiceURL(of media: ConversationThreadMedia) -> URL? {
        media.localFileURL
            ?? media.assetID.flatMap { VoiceFileCache.shared?.fileURL(forAsset: $0) }
            ?? media.url
    }

    private func toggleVoice(_ id: String) {
        guard let message = messagesByID[id], let media = message.media, let url = voiceURL(of: media) else { return }
        if voicePlayer.messageID == id, voicePlayer.state == .playing {
            voicePlayer.pause()
            return
        }
        playVoice(id, url: url)
    }

    private func playVoice(_ id: String, url: URL) {
        rememberShownVoice()
        listenToVoicePlayer()
        voiceShownID = id
        let resume = voicePlayer.messageID == id && voicePlayer.state == .paused
        voicePlayer.play(id, url: url, from: resume ? nil : voicePositions[id])
        if let message = messagesByID[id], !message.isMine { voicePlayed.markPlayed(id) }
        refreshVoices()
    }

    /// A tap seeks there; a drag scrubs. On a message not playing, it moves
    /// its position without playing.
    private func seekVoice(_ id: String, to fraction: Double, scrubbing: Bool) {
        if voicePlayer.messageID == id {
            voicePlayer.seek(to: fraction)
        }
        voicePositions[id] = fraction
        refreshVoices()
    }

    /// The message the player spoke for keeps where it was.
    private func rememberShownVoice() {
        guard let shown = voiceShownID, voicePlayer.messageID == shown else { return }
        switch voicePlayer.state {
        case .playing, .paused:
            if let progress = voicePlayer.progress { voicePositions[shown] = progress }
        case .ended:
            voicePositions[shown] = nil
        default:
            break
        }
    }

    private func listenToVoicePlayer() {
        voicePlayer.onChange = { [weak self] in self?.voicePlayerChanged() }
    }

    private func voicePlayerChanged() {
        if voicePlayer.state == .ended, let id = voicePlayer.messageID {
            voicePositions[id] = nil
            if let next = Self.nextVoice(after: id, in: orderedMessages, isPlayed: { self.voicePlayed.isPlayed($0) }),
               let media = messagesByID[next]?.media, let url = voiceURL(of: media) {
                playVoice(next, url: url)
                return
            }
        }
        refreshVoices()
    }

    /// The next one plays on its own (Telegram's playlist): the message
    /// RIGHT AFTER a received voice message that ended, when it is a received
    /// voice message not played yet — anything else stops it.
    static func nextVoice(
        after id: String, in messages: [ConversationThreadMessage], isPlayed: (String) -> Bool
    ) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }), !messages[index].isMine,
              messages.indices.contains(index + 1) else { return nil }
        let next = messages[index + 1]
        guard next.media?.kind == .voice, !next.isMine, !isPlayed(next.id) else { return nil }
        return next.id
    }

    private var orderedMessages: [ConversationThreadMessage] {
        if case .content(let messages) = phase { return messages }
        return []
    }

    /// Every voice bubble on screen, from the player's state — no reload.
    private func refreshVoices() {
        for case let cell as ThreadRowCell in collectionView.visibleCells {
            guard case .message(let id) = dataSource.itemIdentifier(for: collectionView.indexPath(for: cell) ?? IndexPath()),
                  let message = messagesByID[id], let state = voiceState(for: message) else { continue }
            cell.voiceView.update(state)
        }
    }

    private func stopVoice() {
        guard voiceShownID != nil else { return }
        voicePlayer.stop()
        voicePlayer.onChange = nil
        voiceShownID = nil
    }

    #if DEBUG
    func debugToggleVoice(_ id: String) { toggleVoice(id) }
    func debugVoiceState(_ id: String) -> ThreadVoiceView.State? { messagesByID[id].flatMap(voiceState(for:)) }
    func debugVoiceEnded() { voicePlayerChanged() }
    #endif
}

// MARK: - Recording (#2102)

extension ConversationThreadViewController {
    /// The composer records when the screen is the full conversation and
    /// its driver sends voice (`recordsVoice`, declared in the contract):
    /// the empty field's long press (#2183), a message's five minutes.
    func installVoiceComposer() {
        guard recordsVoice, voiceComposer == nil else { return }
        let composer = VoiceComposer(for: .message, draftKey: driver.presenceKey ?? peer.id?.rawValue)
        composer.onSend = { [weak self] take in self?.driver.send(voice: take) }
        composer.onHint = { [weak self] hint in
            guard let self else { return }
            Feedback.info(hint, symbol: "mic", from: self)
        }
        composer.onPermissionDenied = { [weak self] in self?.offerMicrophoneSettings() }
        composer.attach(to: composeBar, host: view)
        voiceComposer = composer
    }

    /// Once refused, a hold offers Settings (#2102).
    private func offerMicrophoneSettings() {
        let alert = UIAlertController(
            title: "Microphone Access", message: "Allow microphone access to record voice messages.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        present(alert, animated: true)
    }
}
