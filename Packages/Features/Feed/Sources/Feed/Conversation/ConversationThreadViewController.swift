import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import UIKit

/// A conversation, drawn as a text post's screen.
///
/// The pieces are the text page's own, not look-alikes: messages are
/// `CommentRowView`s (avatar, "Name · 14:32", body — the viewer's too), the
/// composer is `CommentsInputBar` resting where the text page rests it, the
/// footer frost is the same `ProgressiveFrostView` band, and the
/// footer is `SnapFooterToolbar` with the emote strip where a post shows its
/// music. What a conversation leaves out is what only a post has: the stake
/// (there is nothing to like), and the footer's save and repost — the strip
/// takes their room. What a conversation adds is a chat's reading order: oldest at the
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
        case empty
        case message(String)
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
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let contextMenu = ThreadRowContextMenu()
    /// The post's composer, so the post's geometry (`SnapActionColumn`): at
    /// rest the rail slot stands where the snap feed's repost bubble stands
    /// (the column's lift above the footer, its inset from the trailing edge)
    /// and wears a PIN for this conversation, whatever the field holds; the
    /// voice note and the send arrow are in the field. Keyboard up, only the
    /// input row rides the keyboard, widening into the pin's width — the pin
    /// stays where it was.
    private let composeBar = CommentsInputBar()

    /// The conversation's pin as the driver last reported it — nil while
    /// there is nothing to pin (a draft).
    private var isPinned: Bool?

    private func renderPinned(_ pinned: Bool?) {
        isPinned = pinned
        composeBar.railFace = .pin(isPinned: pinned == true)
        composeBar.isRailFaceEnabled = pinned != nil
    }
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
    private let olderSpinner = UIActivityIndicatorView(style: .medium)
    private let peerPill = SnapAuthorIdentityView()
    /// The conversation's mute (#719), at the bar's trailing corner beside
    /// the points badge: `bell`, or `bell.slash` once muted. Hidden while
    /// there is nothing to mute (a draft).
    ///
    /// ⚠️ ONE ITEM PER STATE, EACH WITH ITS OWN IDENTIFIER (#729). Two bar
    /// items with one identifier are the same item to UIKit, and swap in a
    /// frame; distinct identifiers get the native Liquid Glass morph when
    /// one replaces the other (`setRightBarButtonItems(_:animated:)`).
    private var muteItem = UIBarButtonItem()
    /// Keeps the bell and the badge two bubbles.
    private let muteSpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
    /// What the bell shows; nil hides it.
    private var muted: Bool?

    private var phase: ConversationThreadPhase = .loading
    private var messagesByID: [String: ConversationThreadMessage] = [:]
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
    /// The phase held back until a rise lands; the newest one wins.
    private var deferredPhase: ConversationThreadPhase?
    /// Delivered messages whose pending row already played the delivery
    /// while the swap waited for its rise: they land plainly (#725).
    private var deliveredEarly: Set<String> = []
    private var peer = ConversationThreadPerson(id: nil, name: "", avatarURL: nil)

    // MARK: The relation (#752)

    /// The pill's relation glyph, as a vertical post's author pill draws it:
    /// "+" (a tap follows), following, friends. Nil graphs draw none.
    private let socialGraph: (any SocialGraphWriting)?
    private let followRelations: (any SocialGraphReading)?
    private var peerRelation: FollowRelation?
    /// Whom `peerRelation` was asked for, so a peer is asked once.
    private var relationAskedFor: ProfileID?
    private var followInFlight = false
    /// Bumped by every ask and every follow: an answer from before either
    /// is stale — a read sent before a follow undid the follow (#752).
    private var relationGeneration = 0
    private var viewer = ConversationThreadPerson(id: nil, name: "You", avatarURL: nil)
    private var hasRenderedContent = false
    /// First content arrived before the stream had a height to pin against —
    /// see `pinToTail`.
    private var owesTailPin = false
    private var hasEstablishedClearance = false
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
        followRelations: (any SocialGraphReading)? = nil
    ) {
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
        if mode == .full {
            configureComposer()
            configureToolbar()
            contextMenu.install(on: collectionView)
            contextMenu.menuProvider = { [weak self] indexPath in self?.menu(at: indexPath) }
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
        // Back from their profile, the relation may have moved.
        resolvePeerRelation(refresh: true)
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
        guard mode == .full else { return }
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
        syncBottomClearance()
        syncDayItem()
        // After the clearance, in the same pass: see `pinToTail`.
        if owesTailPin { pinToTail() }
    }

    /// Where a day's first message rests after a tap on the bar's day,
    /// below the bar's bottom: the stream's own top breath (#750).
    static var dayStartLanding: CGFloat { SnapCommentsLayout.streamTopBreath }

    /// The day on screen, as a bar item left of the bell (#750): a system
    /// glass bubble, interactive. A tap scrolls to that day's first message,
    /// as a search section's pill does. The flow keeps its own day chips,
    /// unpinned (#755).
    ///
    /// ⚠️ ONE ITEM PER DAY, EACH WITH ITS OWN IDENTIFIER (#755), as the bell
    /// (#729): a title edited in place swaps in a frame; a new item under a
    /// new identifier gets the native Liquid Glass morph.
    private var dayItem = UIBarButtonItem()
    private let daySpacer = UIBarButtonItem.fixedSpace(Spacing.sm)
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
        guard view.window != nil else { return placeMuteItem() }
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
            return
        }
        dayPlacementScheduled = false
        placeMuteItem(animated: true)
    }

    private var dayPlacementScheduled = false

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
        let inBar = navigationItem.rightBarButtonItems?.contains { $0 === dayItem } ?? false
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
        // back from #741): the messages run up under the day and the bell
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
            case .empty:
                collectionView.dequeueConfiguredReusableCell(using: emptyCell, for: indexPath, item: item)
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
        composeBar.onVoiceNote = { [weak self] in
            self?.presentNotice("Voice Messages", "Voice messages aren't available yet.")
        }
        // No stake: a conversation has nothing to like. The column keeps its
        // slot where it was: the pin.
        composeBar.showsStake = false
        // The slot's pin, the inbox's own (the driver's). Disabled until the
        // driver reports one (`renderPinned`): a draft has nothing to pin.
        renderPinned(isPinned)
        composeBar.onRailAction = { [weak self] in self?.driver.togglePinned() }

        composerBackdrop.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        composerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBackdrop)
        view.addSubview(composeBar)
        // The BAR rests on the safe area, which the footer toolbar inflates,
        // and never moves: at rest the input row sits `glassGap` above the
        // toolbar's glass and the bar lifts its own column
        // (`SnapActionColumn`). The keyboard guide, measured from the screen's
        // edge, lifts the input row alone the moment the keyboard rises past
        // it (`riseWithKeyboard`) — the pin stays on its station.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            composeBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -SnapActionColumn.trailingInset
            ),
            composeBar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -SnapActionColumn.inputRestingGap
            ),
            composerBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // From the INPUT ROW, as on the post: the lifted slot floats in
            // the band's ramp, and the band rides the keyboard with the row.
            composerBackdrop.topAnchor.constraint(
                equalTo: composeBar.inputRowTopAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
        ])
        composeBar.riseWithKeyboard(of: view.keyboardLayoutGuide)
    }

    /// The post's footer, with the peer's pill where the post's author pill
    /// is (#671): [peer pill] … [⋯]. The emote strip that held the slot is
    /// gone — the composer's own emote button is the way to emotes.
    private func configureToolbar() {
        let more = SnapFooterToolbar.makeMoreButton(menu: UIMenu(children: [
            UIAction(title: "View Profile", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                self?.driver.didTapIdentity()
            },
        ]))
        toolbarItems = SnapFooterToolbar.items(leading: peerPill, actions: mediaButtons(), more: more)
    }

    /// `[📷 🖼]` left of the ⋯ (#681): the camera and the library, for a
    /// thread whose driver sends media.
    private func mediaButtons() -> [UIButton] {
        guard mode == .full, driver.sendsMedia else { return [] }
        let camera = SnapNavControls.makeToolbarActionButton(systemName: "camera")
        camera.accessibilityLabel = "Camera"
        camera.addAction(UIAction { [weak self] _ in self?.pickMedia(.camera) }, for: .primaryActionTriggered)
        let library = SnapNavControls.makeToolbarActionButton(systemName: "photo.on.rectangle")
        library.accessibilityLabel = "Photo Library"
        library.addAction(UIAction { [weak self] _ in self?.pickMedia(.library) }, for: .primaryActionTriggered)
        return [camera, library]
    }

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
        // carries the day and the bell.
        navigationItem.titleView = nil
        navigationItem.title = nil

        peerPill.setFollowBadge(.none)
        peerPill.setOverMedia(false)
        peerPill.onAuthorTapped = { [weak self] _ in self?.driver.didTapIdentity() }
        peerPill.onFollowTapped = { [weak self] id in self?.followPeer(id) }
        // The pill is the toolbar's (#671); a preview (no toolbar) keeps it
        // in the bar.
        var items = pillRidesToolbar ? [] : [UIBarButtonItem(customView: peerPill)]
        // No points badge on a conversation (#738): the bell alone trails.
        navigationItem.rightBarButtonItems = items
        placeMuteItem()
    }

    /// The bell takes the corner, right of the points badge (#719): `[0]` is
    /// the trailing edge, and a fixed space keeps the two bubbles apart.
    private func placeMuteItem(replacing old: UIBarButtonItem? = nil, animated: Bool = false) {
        let current = navigationItem.rightBarButtonItems ?? []
        var items = current.filter {
            $0 !== muteItem && $0 !== muteSpacer && $0 !== old && $0 !== daySpacer && !Self.isDayItem($0)
        }
        // `[0]` is the trailing edge: the bell takes the corner, the day
        // stands left of it (#750).
        var trailing: [UIBarButtonItem] = []
        if mode == .full, muted != nil { trailing.append(muteItem) }
        // A day placement on its way, animated: an unanimated placement (the
        // bell's first) leaves the day as it stands rather than popping it in.
        let day = dayPlacementScheduled && !animated ? current.first(where: Self.isDayItem)
            : (dayItemShown ? dayItem : nil)
        if mode == .full, let day {
            if !trailing.isEmpty { trailing.append(daySpacer) }
            trailing.append(day)
        }
        items = trailing + (items.isEmpty || trailing.isEmpty ? [] : [muteSpacer]) + items
        // The same items again would restart — and cut short — a transition
        // already running (#756).
        guard items.count != current.count || zip(items, current).contains(where: { $0 !== $1 }) else { return }
        if animated { debugAnimatedBarPlacements += 1 }
        navigationItem.setRightBarButtonItems(items, animated: animated)
    }

    /// How many animated placements the bar took. Tests.
    private(set) var debugAnimatedBarPlacements = 0

    /// Any day item — the one on show, or one a change of day replaced.
    private static func isDayItem(_ item: UIBarButtonItem) -> Bool {
        item.identifier?.hasPrefix("conversation.day.") == true
    }

    /// The bell for `muted`: a tap toggles, a long press offers how long
    /// (#729). Its identifier names its state, so the bar morphs between
    /// the two.
    private func makeMuteItem(muted: Bool) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: nil,
            image: UIImage(systemName: muted ? "bell.slash" : "bell"),
            primaryAction: UIAction { [weak self] _ in self?.setMuted(!muted, until: nil) },
            menu: muteMenu(muted: muted)
        )
        item.identifier = muted ? Self.mutedBellID : Self.bellID
        item.tintColor = .label
        item.accessibilityLabel = "Notifications"
        item.accessibilityValue = muted ? "Muted" : "On"
        return item
    }

    static let bellID = "conversation.bell"
    static let mutedBellID = "conversation.bell.muted"

    /// How long a mute lasts, as the long press offers it (#729).
    static let muteDurations: [(title: String, toast: String, seconds: TimeInterval?)] = [
        ("For 1 Hour", "Muted for 1 hour", 3_600),
        ("For 8 Hours", "Muted for 8 hours", 8 * 3_600),
        ("For 1 Day", "Muted for 1 day", 86_400),
        ("For 1 Week", "Muted for 1 week", 7 * 86_400),
        ("Until I Turn It Back On", "Notifications muted", nil),
    ]

    private func muteMenu(muted: Bool) -> UIMenu {
        let durations = Self.muteDurations.map { duration in
            UIAction(title: duration.title) { [weak self] _ in
                self?.setMuted(true, until: duration.seconds.map { Date().addingTimeInterval($0) }, toast: duration.toast)
            }
        }
        let mute = UIMenu(title: muted ? "Mute Again" : "Mute Notifications", image: UIImage(systemName: "bell.slash"),
                          options: muted ? [] : .displayInline, children: durations)
        guard muted else { return UIMenu(children: [mute]) }
        let unmute = UIAction(title: "Unmute", image: UIImage(systemName: "bell")) { [weak self] _ in
            self?.setMuted(false, until: nil)
        }
        return UIMenu(children: [unmute, mute])
    }

    /// Mutes or unmutes through the driver, and says so (#729): the same
    /// bottom toast as "You're signed in".
    private func setMuted(_ mute: Bool, until: Date?, toast: String? = nil) {
        driver.setMuted(mute, until: until)
        ToastView.present(
            toast ?? (mute ? "Notifications muted" : "Notifications on"),
            symbol: mute ? "bell.slash.fill" : "bell.fill",
            in: view,
            // Over the composer, which rests where the toast would.
            above: composeBar.inputRowTopAnchor
        )
    }

    /// The bell follows the conversation's mute; it appears once there is a
    /// conversation to mute and leaves if there is none.
    private func renderMuted(_ muted: Bool?) {
        let was = self.muted
        self.muted = muted
        guard let muted else {
            if was != nil {
                placeMuteItem()
                fitTrailingRun()
            }
            return
        }
        guard was != muted else { return }
        let old = muteItem
        muteItem = makeMuteItem(muted: muted)
        // A first appearance lands; a change morphs, glass to glass.
        placeMuteItem(replacing: old, animated: was != nil)
        if was == nil { fitTrailingRun() }
    }

    #if DEBUG
    /// The bell on the bar, nil while there is none. Tests.
    var debugMuteItem: UIBarButtonItem? {
        navigationItem.rightBarButtonItems?.first { $0 === muteItem }
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
        driver.onViewerChange = { [weak self] person in self?.adoptViewer(person) }
        driver.onSendingChange = { [weak self] sending in self?.composeBar.isSending = sending }
        driver.onReplyStateChange = { [weak self] draft in self?.renderReply(draft) }
        driver.onActionNotice = { [weak self] title, message in self?.presentNotice(title, message) }
        driver.onPinnedChange = { [weak self] pinned in self?.renderPinned(pinned) }
        driver.onMutedChange = { [weak self] muted in self?.renderMuted(muted) }
        driver.onLoadingOlderChange = { [weak self] loading in self?.setLoadingOlder(loading) }
    }

    private func configureOlderSpinner() {
        olderSpinner.hidesWhenStopped = true
        olderSpinner.color = .secondaryLabel
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
        if let wait = riseStillLanding(before: phase) {
            // The server answered mid-rise: the spinner goes at once — the
            // row it sits in is swapped once the rise has landed.
            playEarlyDeliveries(in: phase)
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
            statusView.isHidden = true
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
        applySnapshot(animated: hasRenderedContent && anchor == nil && swappedIDs.isEmpty)
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
            scrollToBottom(animated: true)
        }
    }

    private func applySnapshot(animated: Bool) {
        let previous = dataSource.snapshot()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        switch phase {
        case .loading:
            headerPolicy.daySections = false
            snapshot.appendSections([.main])
            let viewport = collectionView.bounds.height > 0 ? collectionView.bounds.height : view.bounds.height
            let count = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: viewport)
            snapshot.appendItems((0..<count).map(Item.skeleton))
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
                snapshot.appendItems([.message(message.id)], toSection: .day(day))
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
    }

    /// Whether the last render animated its differences. Tests.
    private(set) var debugLastApplyAnimated: Bool?

    private func isAwaitingDelivery(_ message: ConversationThreadMessage) -> Bool {
        message.isMine && message.media == nil && message.delivery != .sent
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
            author: message.isMine ? viewer : peer,
            isGroupMember: !message.isMine && peer.id == nil && !peer.name.isEmpty
        )
    }

    #if DEBUG
    /// Every row configured, in order — what a render re-drew (#725). Tests.
    var debugConfiguredIDs: [String] = []
    #endif

    private func configure(_ cell: ThreadRowCell, messageID: String) {
        guard let message = messagesByID[messageID] else { return }
        renderedRows[messageID] = rowSignature(for: message)
        #if DEBUG
        debugConfiguredIDs.append(messageID)
        #endif
        let author = message.isMine ? viewer : peer
        let name: String
        if message.isMine {
            name = author.name.isEmpty ? "You" : author.name
        } else if peer.id == nil, !peer.name.isEmpty {
            // A GROUP: the header's name is every member's, joined, and chat
            // carries no per-member name to sign a row with — so a neutral
            // label rather than attributing each message to the whole group.
            name = "Member"
        } else {
            name = author.name.isEmpty ? "Message" : author.name
        }
        cell.row.configure(
            with: CommentDisplayModel(
                id: message.id,
                authorID: message.senderID,
                authorName: name,
                // A text of the viewer's on its way, or failed, has no time
                // yet: the spinner or the mark stands in its place (#725).
                metaText: isAwaitingDelivery(message) ? "" : Self.timeFormatter.string(from: message.sentAt),
                body: message.body,
                avatarURL: name == "Member" ? nil : author.avatarURL
            ),
            imagePipeline: imagePipeline
        )
        cell.row.setLikeControlHidden(true)
        cell.row.onAvatarTap = message.isMine ? nil : { [weak self] in self?.driver.didTapIdentity() }
        // A row tap answers it — the post's grammar. Nothing to answer in a peek.
        // While the keyboard is up, the tap retires it instead (see
        // `retireKeyboardOr`).
        cell.row.onReplyTap = mode == .full ? { [weak self] in
            guard let self else { return }
            self.retireKeyboardOr { self.driver.beginReply(to: messageID) }
        } : nil
        if let quote = message.quote {
            cell.setQuote((quote.author, quote.snippet))
            cell.onQuoteTap = { [weak self] in self?.scrollToMessage(quote.messageID) }
        } else {
            cell.setQuote(nil)
        }
        cell.mediaView.configure(message.media, delivery: message.delivery, pipeline: imagePipeline)
        // A text message of the viewer's shows whether it is on its way
        // (#719); a failed one is sent again by a tap.
        cell.setDelivery(
            message.isMine && message.media == nil ? message.delivery : nil,
            time: Self.timeFormatter.string(from: message.sentAt)
        )
        if message.isMine, message.media == nil, message.delivery == .failed {
            cell.row.onReplyTap = { [weak self] in self?.driver.retry(messageID) }
        }
        if arrivingIDs.remove(messageID) != nil {
            arrivalStarts[messageID] = CACurrentMediaTime()
            cell.playArrival()
        } else if deliveredIDs.remove(messageID) != nil {
            cell.playDelivered(revealing: Self.timeFormatter.string(from: message.sentAt))
        }
        cell.mediaView.onTap = message.media == nil ? nil : { [weak self, weak cell] in
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
                      let index = goneSending.firstIndex(where: { $0.body == message.body && $0.media == nil }) {
                goneSending.remove(at: index)
                if deliveredEarly.remove(message.id) == nil { deliveredIDs.insert(message.id) }
                swappedIDs.insert(message.id)
            }
        }
        arrivalStarts = arrivalStarts.filter { messagesByID[$0.key] != nil }
        renderedRows = renderedRows.filter { messagesByID[$0.key] != nil }
    }

    /// The pending rows a held-back phase delivers play their delivery now.
    private func playEarlyDeliveries(in phase: ConversationThreadPhase) {
        guard case .content(let messages) = phase else { return }
        var pending = messagesByID.values.filter { $0.isMine && $0.delivery == .sending && $0.media == nil }
        for message in messages where message.isMine && message.delivery == .sent && messagesByID[message.id] == nil
            && !deliveredEarly.contains(message.id) {
            guard let index = pending.firstIndex(where: { $0.body == message.body && !messages.map(\.id).contains($0.id) })
            else { continue }
            let row = pending.remove(at: index)
            guard let path = dataSource.indexPath(for: .message(row.id)),
                  let cell = collectionView.cellForItem(at: path) as? ThreadRowCell else { continue }
            cell.playDelivered(revealing: Self.timeFormatter.string(from: message.sentAt), carryingSpinner: false)
            deliveredEarly.insert(message.id)
        }
    }

    /// Delivered messages that took a pending row's place in this render.
    private var swappedIDs: Set<String> = []

    /// How long until the rise of a pending message this phase would retire
    /// lands; nil when nothing is mid-rise.
    private func riseStillLanding(before phase: ConversationThreadPhase) -> TimeInterval? {
        guard case .content(let messages) = phase, !arrivalStarts.isEmpty else { return nil }
        let ids = Set(messages.map(\.id))
        let now = CACurrentMediaTime()
        let waits = arrivalStarts.compactMap { id, start -> TimeInterval? in
            guard !ids.contains(id) else { return nil }
            let left = ThreadRowCell.arrivalDuration - (now - start)
            return left > 0 ? left : nil
        }
        return waits.max()
    }

    private func adoptPeer(_ person: ConversationThreadPerson) {
        peer = person
        // Named for VoiceOver, not drawn: no title in the bar.
        view.accessibilityLabel = person.name.isEmpty ? nil : "Conversation with \(person.name)"
        // The @handle under the name once known (#752), as a vertical post's
        // author pill wears it.
        let meta = person.handle.map { "@\($0)" } ?? ""
        peerPill.setPerson(
            id: person.id, name: person.name, meta: meta, avatarURL: person.avatarURL, pipeline: imagePipeline
        )
        if person.id != relationAskedFor { setPeerRelation(nil) }
        resolvePeerRelation()
        fitTrailingRun()
        if hasRenderedContent { applySnapshot(animated: false) }
    }

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
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = message.body
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
                self?.driver.delete(messageID)
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = self.view
            sheet.popoverPresentationController?.sourceRect = CGRect(
                x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0
            )
            self.present(sheet, animated: true)
        }
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

    private var isNearBottom: Bool {
        let insets = collectionView.adjustedContentInset
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - insets.bottom
        return visibleBottom >= collectionView.contentSize.height - 120
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
        for _ in 0..<4 {
            let heightBefore = collectionView.contentSize.height
            scrollToBottom(animated: false)
            collectionView.layoutIfNeeded()
            if abs(collectionView.contentSize.height - heightBefore) < 0.5 { break }
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
        guard composeBar.bounds.height > 0 else { return }
        // The bar's top at rest, the risen input row's while the keyboard
        // holds it above the bar (the pin stays down there, under it).
        let composerTop = composeBar.occupiedMinY
        let inset = max(0, view.bounds.height - composerTop - view.safeAreaInsets.bottom) + Spacing.sm
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

    /// The peer pill's share of the nav bar: the bar less its margins, the
    /// back button, and the bell when there is one. Measured, and
    /// applied before the bar first lays the run out (see `viewWillAppear`).
    /// Whether the peer pill is the toolbar's leading item (#671): on the full
    /// thread, which has a toolbar; a preview keeps it in the bar.
    private var pillRidesToolbar: Bool { mode == .full }

    private func fitTrailingRun() {
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }
        let itemPadding: CGFloat = 18
        if pillRidesToolbar {
            // The toolbar's leading slot (#671): the bar less its margins, the
            // ⋯ bubble beside it and — sending media (#681) — the camera and
            // library capsule, the snap feed's repost and save capsule's size.
            let capsule: CGFloat = mediaButtons().isEmpty ? 0 : 2 * 44 + itemPadding + Spacing.sm
            peerPill.setWidthBudget(bar - 16 * 2 - (48 + itemPadding) - capsule)
            return
        }
        var budget = bar - 16 * 2 - (36 + itemPadding) - itemPadding
        // The bell beside it (#719).
        if mode == .full, muted != nil { budget -= 44 + itemPadding + Spacing.sm }
        peerPill.setWidthBudget(budget)
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

    private func presentNotice(_ title: String, _ message: String) {
        guard presentedViewController == nil else { return }
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
        guard mode == .full, hasRenderedContent, scrollView.isTracking || scrollView.isDecelerating,
              scrollView.contentOffset.y + scrollView.adjustedContentInset.top < scrollView.bounds.height
        else { return }
        driver.loadOlder()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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
            self.setPeerRelation(relation)
        }
    }

    private func setPeerRelation(_ relation: FollowRelation?) {
        peerRelation = relation
        let badge = relation.map(SnapAuthorIdentityView.FollowBadge.init) ?? .none
        peerPill.setFollowBadge(badge, animated: view.window != nil)
        fitTrailingRun()
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
        setPeerRelation(before.settingFollow(true))
        Task { [weak self] in
            let accepted = (try? await socialGraph.setFollowing(true, for: id)) != nil
            guard let self else { return }
            self.followInFlight = false
            if !accepted, self.peer.id == id { self.setPeerRelation(before) }
            // The peer changed mid-follow: its relation was never asked.
            if self.peer.id != id { self.resolvePeerRelation() }
        }
    }

    /// The pill's relation glyph. Tests.
    var debugPeerFollowBadge: SnapAuthorIdentityView.FollowBadge { peerPill.followBadge }
}
