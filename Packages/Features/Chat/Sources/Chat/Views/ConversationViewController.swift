import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The conversation thread, Telegram-grade on stock UIKit: a compositional-
/// layout collection view with diffable snapshots and self-sizing bubble
/// cells, day chips pinned per section, a floating glass compose bar docked to
/// the keyboard through `keyboardLayoutGuide`, and the favorites sticker strip
/// riding the navigation controller's own static bottom toolbar beneath it.
///
/// Section identity = `TranscriptDay`, item identity = message id; row models
/// live in `rowsByID` and rows whose *content* changed (a bubble's run
/// position shifts when a same-sender message lands after it) are
/// reconfigured in place, so appends never rebuild the transcript.
final class ConversationViewController: UIViewController {
    /// `.full` is the pushed thread. `.preview` is the context-menu peek:
    /// no compose bar (typing is impossible in a peek), no keyboard wiring,
    /// no pull-to-refresh — just the live, scrollable transcript.
    enum Mode { case full, preview }

    private let viewModel: ConversationViewModel
    private let mode: Mode

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let inputBar = ChatInputBar()
    /// Rides the navigation controller's own bottom toolbar as a bar item,
    /// static at the bottom of the screen — it does not track the keyboard.
    private let stickerStrip = FavoriteStickerStripView()
    private let identityView = ConversationIdentityView()
    private let refreshControl = UIRefreshControl()
    private let skeletonView = TranscriptSkeletonView()
    private let statusLabel = UILabel()

    private var dataSource: UICollectionViewDiffableDataSource<TranscriptDay, String>!
    private var rowsByID: [String: MessageRowModel] = [:]
    private var newestRowID: String?
    private var hasRenderedContent = false
    /// The correspondent's name, once resolved — labels quoted replies from
    /// the peer. Empty until `onTitleChange`; the view model re-emits content
    /// when it lands, so late resolution still names existing quotes.
    private var peerName = ""
    /// A message a quote-tap is scrolling toward; flashed once the scroll
    /// settles (the destination cell isn't realized until then).
    private var pendingFlashID: String?
    /// The bubble currently in "Select Text" mode, if any.
    private weak var textSelectionCell: MessageCell?
    /// Tap-anywhere-else recognizer that ends text selection; live only while
    /// selecting. Rides on the collection view so the floating Copy/Share
    /// callout (a separate view tree) never trips it.
    private lazy var textSelectionDismissTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTextSelectionDismissTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()
    /// Preview only: the platter can resize while animating in, stranding
    /// the one-shot tail scroll mid-history — tracked to re-pin on change.
    private var lastPreviewLayoutSize = CGSize.zero
    /// The bubble currently being dragged for a reply, if any. While it is set
    /// the transcript's scrolling is suspended, so the swipe runs on a purely
    /// horizontal axis; identity is tracked (not a bare flag) so a stale end
    /// call from a recycled cell can't unlock a swipe already in progress.
    private weak var replySwipingCell: MessageCell?
    /// False until the compose bar's resting clearance has been measured once.
    /// Establishing that first inset is not keyboard travel, so it must not
    /// drag the transcript with it.
    private var hasEstablishedClearance = false
    /// Distance from the transcript's tail at the moment the finger went down —
    /// the reading position an interactive dismissal has to give back.
    private var dragStartTailDistance: CGFloat?
    /// Set only when a clearance change actually landed mid-drag; the pin owed
    /// back to the list once the finger lifts.
    private var deferredTailDistance: CGFloat?

    /// Text to seed the composer with — a profile link sent from the share
    /// sheet. Applied once, on first load; never sent automatically.
    private let prefill: String

    private let imagePipeline: ImagePipeline?
    private let avatars: (any PeerAvatarProviding)?
    private var headerAvatarTask: Task<Void, Never>?
    /// The peer the header is currently showing, so a late fetch cannot land
    /// on a thread that has since been rebound.
    private var headerPeerID: ProfileID?

    init(
        viewModel: ConversationViewModel,
        mode: Mode = .full,
        prefill: String = "",
        imagePipeline: ImagePipeline? = nil,
        avatars: (any PeerAvatarProviding)? = nil
    ) {
        self.viewModel = viewModel
        self.mode = mode
        self.prefill = prefill
        self.imagePipeline = imagePipeline
        self.avatars = avatars
        super.init(nibName: nil, bundle: nil)
        // A thread takes the full screen height: the system hides the tab bar
        // with the push and restores it on pop. Safe here — unlike the feed's
        // manually managed bar (see `FeedFlowCoordinator`), a thread pops via
        // the standard gesture, which this flag's choreography scrubs with.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Fetches the correspondent's picture for the header pill. The initials
    /// are already on screen — this only ever replaces them, never delays them.
    private func loadHeaderAvatar(for peerID: ProfileID?) {
        guard peerID != headerPeerID || peerID == nil else { return }
        headerAvatarTask?.cancel()
        headerAvatarTask = nil
        headerPeerID = peerID
        identityView.setPicture(nil)

        guard let peerID, let avatars, let imagePipeline else { return }
        headerAvatarTask = Task { [weak self] in
            let urls = await avatars.avatarURLs(for: [peerID])
            guard !Task.isCancelled, let url = urls[peerID] else { return }
            guard let image = try? await imagePipeline.image(for: url) else { return }
            guard let self, !Task.isCancelled, self.headerPeerID == peerID else { return }
            self.identityView.setPicture(image)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inputBar.setDraftText(prefill)
        title = "Conversation"
        view.backgroundColor = .systemBackground
        configureNavigationItem()
        configureCollectionView()
        configureStatusViews()
        if mode == .full {
            configureInputBar()
            // ONE notification covers the whole surface: raise, dismiss, and
            // every mid-session height change (autocorrect bar, hardware
            // keyboard toggling, floating/split). Show-only misses the rest.
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil
            )
        }
        configureSkeleton()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onSendingChange = { [weak self] sending in self?.inputBar.isSending = sending }
        viewModel.onActionNotice = { [weak self] title, message in
            self?.presentNotice(title: title, message: message)
        }
        viewModel.onTitleChange = { [weak self] name in
            guard let self else { return }
            // `title` still carries the name (it feeds pushed screens' back
            // labels); the visible identity lives in the trailing pill.
            self.title = name
            self.peerName = name
            self.identityView.setIdentity(
                name: name,
                monogram: ConversationDisplayModel.monogram(name)
            )
        }
        viewModel.onPeerChange = { [weak self] peerID in
            self?.loadHeaderAvatar(for: peerID)
        }
        viewModel.onReplyStateChange = { [weak self] draft in
            guard let self else { return }
            if let draft {
                self.inputBar.setReplyContext(author: draft.author, snippet: draft.snippet)
                self.inputBar.focus()
            } else {
                self.inputBar.clearReplyContext()
            }
        }
        render(.loading)
        viewModel.viewDidLoad()

        #if DEBUG
        // `-chat-send-demo` sends a canned message ~2.5s after the thread
        // opens — the append + reconfigure + follow-scroll path is visible
        // in-sim without typing (no tap/keyboard injection available).
        if mode == .full, ProcessInfo.processInfo.arguments.contains("-chat-send-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.viewModel.send("Sent from the demo — watch me slide in 🚀")
            }
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The identity is bound synchronously in `viewDidLoad` (directory
        // warm-start); resolve the bar's pending item layout NOW, while the
        // push transition is being set up, so the pill animates in at its
        // final dimensions instead of settling after the transition.
        navigationController?.navigationBar.layoutIfNeeded()
        // The sticker toolbar belongs to this screen only — the inbox behind it
        // has none. Shown during the push so it slides in with the transition
        // rather than popping in after it.
        if mode == .full {
            navigationController?.setToolbarHidden(false, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Taken away on the way out, or the inbox inherits an empty bar.
        if mode == .full {
            navigationController?.setToolbarHidden(true, animated: animated)
        }
        // Don't strand a text selection when navigating away.
        endTextSelection()
        // Nor a suspended scroll: a swipe interrupted by the pop gesture never
        // resolves, and the transcript would come back frozen.
        unlockTranscriptScrolling()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // No bar in a preview: the transcript owns the full card height. But
        // the platter's bounds settle over a few passes while it animates in
        // — keep the tail pinned across size changes until then. Never while
        // a finger is down, so user scrolling inside the peek always wins.
        guard mode == .full else {
            if collectionView.bounds.size != lastPreviewLayoutSize {
                lastPreviewLayoutSize = collectionView.bounds.size
                if hasRenderedContent, !collectionView.isTracking {
                    scrollToBottom(animated: false)
                }
            }
            return
        }
        // The strip's own width is the one thing it cannot work out: it is a
        // bar-item custom view whose content has no intrinsic width, and it is
        // not in the toolbar's hierarchy until layout. The bar's margins are
        // already accounted for by the item wrapper, so the view's width is the
        // right budget.
        stickerStrip.setPreferredWidth(view.bounds.width - Spacing.md * 2)
        // The transcript scrolls under the floating bar: keep a clearance
        // inset matching the bar's overlap beyond the bottom safe area, and
        // carry the content the same distance. Runs on every keyboard-guide-
        // driven pass, so it tracks docking, undocking and scrubs alike.
        syncTranscriptClearance()
    }

    // MARK: - Setup

    /// The posts-layout doctrine (see `SnapFeedViewController`): identity
    /// rides the bar's trailing slot as one stable custom view — here
    /// `[avatar] [name]` — and the centered title slot stays clear.
    private func configureNavigationItem() {
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: identityView)]
        // Keep `title` for back labels but suppress its centered rendering.
        navigationItem.titleView = UIView()
        // Identity tap → the correspondent's profile, through the route seam.
        identityView.onTapped = { [weak self] in self?.viewModel.didTapIdentity() }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let rowSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(44)
            )
            let section = NSCollectionLayoutSection(
                group: .vertical(layoutSize: rowSize, subitems: [NSCollectionLayoutItem(layoutSize: rowSize)])
            )
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(36)
                ),
                elementKind: DayHeaderView.elementKind,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        // Scrolling stays fully live in BOTH modes — a peek is a real,
        // interactive transcript, not a snapshot.
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        // Delegate exists for the bubble context menu; scrolling stays stock.
        collectionView.delegate = self
        collectionView.pin(to: view)

        if mode == .full {
            refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
            collectionView.refreshControl = refreshControl
            // Tap the transcript to put the keyboard away — the partner to the
            // `.interactive` drag above, and the reason the trailing button no
            // longer has to double as a dismiss control. `cancelsTouchesInView`
            // stays false so the tap still reaches the cells underneath (bubble
            // taps, link taps); this recognizer only ever ends editing, and
            // `endEditing` is a no-op when nothing is first responder.
            let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardFromTranscript))
            dismissTap.cancelsTouchesInView = false
            collectionView.addGestureRecognizer(dismissTap)
        } else {
            // No compose bar to clear in a peek, but the last bubble should
            // not sit flush on the platter's bottom edge. Static — the
            // preview has no keyboard or bar to track, so one inset at
            // configure time is the whole story.
            collectionView.contentInset.bottom = Spacing.md
            collectionView.verticalScrollIndicatorInsets.bottom = Spacing.md
        }

        let cellRegistration = UICollectionView.CellRegistration<MessageCell, String> {
            [weak self] cell, _, id in
            guard let self, let row = self.rowsByID[id] else { return }
            cell.configure(with: row)
            cell.delegate = self
            // No compose bar to reply into inside the context-menu peek.
            cell.isReplySwipeEnabled = self.mode == .full
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<DayHeaderView>(
            elementKind: DayHeaderView.elementKind
        ) { [weak self] header, _, indexPath in
            guard let days = self?.dataSource.snapshot().sectionIdentifiers,
                  indexPath.section < days.count else { return }
            header.configure(title: days[indexPath.section].title)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func configureInputBar() {
        view.addSubview(inputBar)
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        // The bottom mirror of the nav bar's soft scroll edge: the system draws
        // the same progressive fade-blur behind this container's region, shaped
        // around its glass elements — and because the effect is bound to the
        // VIEW, it tracks every keyboard-guide move with no geometry here.
        let edgeEffect = UIScrollEdgeElementContainerInteraction()
        edgeEffect.scrollView = collectionView
        edgeEffect.edge = .bottom
        inputBar.addInteraction(edgeEffect)
        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.md),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.md),
            // The dock: the guide tracks the keyboard, including interactive
            // dismissal scrubs, so the bar rides it with no keyboard math. With
            // the keyboard down the guide rests on the safe area — which the
            // navigation controller's toolbar has already inflated — so the bar
            // floats just above the static sticker toolbar.
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm)
        ])

        // The strip is ONE custom item on the navigation controller's own
        // toolbar (the feed's arrangement), so it stays put at the bottom of
        // the screen while the composer rides the keyboard above it.
        stickerStrip.onSelect = { [weak self] sticker in
            self?.inputBar.insertIntoComposer(sticker.emoji)
        }
        toolbarItems = [UIBarButtonItem(customView: stickerStrip)]

        inputBar.onSend = { [weak self] text in self?.viewModel.send(text) }
        inputBar.onCancelReply = { [weak self] in self?.viewModel.cancelReply() }
        // Honest seam: chat.v1 SendMessage is text-only today. The affordance
        // ships per the design spec; the picker wires in with the media plane.
        inputBar.onAttachMedia = { [weak self] in
            self?.presentNotice(
                title: "Media Messages",
                message: "Sending photos and videos isn't available yet."
            )
        }
        // Same honest seam as media: chat.v1 carries no voice payload, so the
        // mic affordance ships and says so rather than miming a recorder.
        inputBar.onRecordVoice = { [weak self] in
            self?.presentNotice(
                title: "Voice Messages",
                message: "Recording voice messages isn't available yet."
            )
        }
    }

    @objc private func dismissKeyboardFromTranscript() {
        view.endEditing(true)
    }

    private func presentNotice(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// The transcript skeleton sits where the transcript will: full width,
    /// tail anchored just above the compose bar (or the safe area in a
    /// preview, which has no bar) — the same clearance the live transcript
    /// keeps. Its top rides the view edge so the pattern clips under the nav
    /// bar like scrolled-away history.
    private func configureSkeleton() {
        skeletonView.isHidden = true
        skeletonView.constrain(in: view) { parent in
            skeletonView.topAnchor.constraint(equalTo: parent.topAnchor)
            skeletonView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            skeletonView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            // The safe area carries the accessory's height in `.full`, so one
            // anchor now serves both modes — the bar itself lives in another
            // view hierarchy and can no longer be constrained to.
            mode == .full
                ? skeletonView.bottomAnchor.constraint(
                    equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.md
                )
                : skeletonView.bottomAnchor.constraint(
                    equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.md
                )
        }
    }

    private func configureStatusViews() {
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    // MARK: - Render

    private func render(_ phase: ConversationViewModel.Phase) {
        switch phase {
        case .loading:
            skeletonView.isHidden = false
            collectionView.isHidden = true
            statusLabel.isHidden = true
        case .content(let models):
            refreshControl.endRefreshing()
            statusLabel.text = "No messages yet. Say hi 👋"
            statusLabel.isHidden = !models.isEmpty
            // Transcript first, reveal second: the snapshot (and its tail
            // scroll) settles while the collection is still covered, so the
            // dissolve uncovers finished rows in place.
            applyTranscript(for: models)
            revealContent()
        case .failed(let message):
            refreshControl.endRefreshing()
            skeletonView.isHidden = true
            collectionView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }

    /// Swaps the skeleton for the populated transcript; dissolves only when
    /// actually leaving a skeleton that is on screen.
    private func revealContent() {
        guard !skeletonView.isHidden, view.window != nil else {
            skeletonView.isHidden = true
            collectionView.isHidden = false
            return
        }
        UIView.transition(
            with: view, duration: 0.35, options: [.transitionCrossDissolve, .curveEaseInOut]
        ) {
            self.skeletonView.isHidden = true
            self.collectionView.isHidden = false
        }
    }

    private func applyTranscript(for models: [MessageDisplayModel]) {
        let sections = ChatTranscript.build(from: models, peerName: peerName)

        var snapshot = NSDiffableDataSourceSnapshot<TranscriptDay, String>()
        var newRows: [String: MessageRowModel] = [:]
        for section in sections {
            snapshot.appendSections([section.day])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.day)
            for row in section.rows { newRows[row.id] = row }
        }
        snapshot.reconfigureItems(newRows.keys.filter { rowsByID[$0] != nil && rowsByID[$0] != newRows[$0] })
        rowsByID = newRows

        // Follow the conversation tail on first render and on new messages —
        // but never yank a reader who has scrolled up into history. A message
        // *I* just sent always wins the scroll (Messages behavior): a reply's
        // compose preview can leave the tail off-screen, and I want to see
        // what I sent regardless.
        let newestID = snapshot.itemIdentifiers.last
        let newestIsMine = newestID.flatMap { newRows[$0] }?.isMine ?? false
        let isFirstRender = !hasRenderedContent
        let shouldFollow = isFirstRender || (newestID != newestRowID && (isNearBottom || newestIsMine))

        dataSource.apply(snapshot, animatingDifferences: !isFirstRender)
        newestRowID = newestID
        hasRenderedContent = true
        if shouldFollow { scrollToBottom(animated: !isFirstRender) }
    }

    // MARK: - Bottom anchoring

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y
            + collectionView.bounds.height
            - collectionView.adjustedContentInset.bottom
        return visibleBottom >= collectionView.contentSize.height - 120
    }

    private func scrollToBottom(animated: Bool) {
        guard let indexPath = newestIndexPath else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
        if !animated {
            // Second pass: the first realizes cells, replacing estimated
            // heights; re-target so a cold open lands exactly on the tail.
            collectionView.layoutIfNeeded()
            collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
        }
    }

    private var newestIndexPath: IndexPath? {
        let snapshot = dataSource.snapshot()
        guard let lastDay = snapshot.sectionIdentifiers.last else { return nil }
        let count = snapshot.numberOfItems(inSection: lastDay)
        guard count > 0 else { return nil }
        return IndexPath(item: count - 1, section: snapshot.numberOfSections - 1)
    }

    // MARK: - Keyboard tracking

    /// Backstop for the keyboard transition, using the notification's own
    /// duration and curve.
    ///
    /// UIKit moves the accessory itself, so nothing here touches the composer.
    /// What this still owns is the TRANSCRIPT: with the bar gone from this
    /// view's hierarchy, a keyboard change no longer invalidates this view's
    /// layout, so `viewDidLayoutSubviews` cannot be relied on to fire — this
    /// notification became the clearance's primary trigger rather than its
    /// backstop, and running the work inside the keyboard's own duration and
    /// curve keeps the transcript travelling with the bar instead of snapping.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard mode == .full, isViewLoaded, view.window != nil,
              let userInfo = notification.userInfo else { return }
        // Defaults match the system's own fallback for a malformed payload.
        let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        // The keyboard reports curve 7 — a private `UIView.AnimationCurve` case
        // with no `AnimationOptions` twin, so it is shifted into the options'
        // curve field verbatim rather than round-tripped through the enum
        // (which would silently degrade it to `.easeInOut` and desync the bar).
        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: UInt(curve) << 16)

        UIView.animate(
            withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]
        ) {
            self.view.layoutIfNeeded()
            self.syncTranscriptClearance()
        }
    }

    /// The transcript's single clearance authority: matches the bottom inset to
    /// the compose bar's overlap and translates the content by the same delta.
    ///
    /// The translation is the fix for a list that sat behind the keyboard: an
    /// inset change only extends the scrollable RANGE, it never moves what is
    /// on screen. Shifting `contentOffset` by the identical delta pins the
    /// visible messages to the bar 1:1 — at the tail and equally deep in
    /// history, where the old near-bottom gate left the view stranded.
    ///
    /// Deliberately NOT gated on "a keyboard transition is in flight": UIKit
    /// usually runs this pass from inside its own keyboard animation before the
    /// notification arrives, so any such flag reads false exactly when it
    /// matters. Riding the layout pass instead makes the shift race-free — and
    /// it inherits that animation's timing for free. The delta guard keeps it
    /// idempotent, so the notification path can safely call it again.
    ///
    /// The same treatment falls out for the compose bar growing (a fifth line
    /// of text, the reply banner): the transcript stays pinned to the bar
    /// instead of hiding behind it.
    private func syncTranscriptClearance() {
        // The bar is back in this view's hierarchy, so its frame is readable
        // again and is the honest source. What the scroll view needs in TOTAL
        // is everything below the bar's top edge plus the breathing gap; the
        // static sticker toolbar is already inside that, since it sits under
        // the bar and inside the bottom safe area.
        let desired = view.bounds.height - inputBar.frame.minY + Spacing.md
        // What UIKit already contributes, MEASURED rather than assumed — the
        // toolbar inflates the bottom safe area, and hard-coding a figure for
        // it would leave the tail short by exactly the difference.
        let systemBottom = collectionView.adjustedContentInset.bottom - collectionView.contentInset.bottom
        let clearance = max(0, desired - systemBottom)
        let delta = clearance - collectionView.contentInset.bottom
        // Sub-point deltas are layout noise, not keyboard travel.
        guard abs(delta) > 0.5 else { return }

        // Both readings must be taken BEFORE the inset moves. Assigning
        // `contentInset.bottom` makes UIKit immediately clamp `contentOffset`
        // into the new range, so the offset read afterwards is already part-way
        // through the travel — adding `delta` to THAT double-counts it and
        // overshoots by a whole keyboard.
        let offsetBefore = collectionView.contentOffset.y
        // How far from the tail the reader was, which is the thing to preserve.
        let distanceFromTail = max(0, maxContentOffsetY - offsetBefore)

        collectionView.contentInset.bottom = clearance
        collectionView.verticalScrollIndicatorInsets.bottom = clearance

        // Measuring the resting clearance for the first time is not travel.
        guard hasEstablishedClearance else {
            hasEstablishedClearance = true
            return
        }
        // Nothing to carry before the first transcript exists.
        guard hasRenderedContent else { return }
        // A finger on the list owns the offset — an interactive dismissal must
        // scrub with it, not fight it. The pin is not abandoned though: the
        // distance measured here is carried to `settleDeferredClearancePin`
        // and applied the moment the gesture lets go, or the transcript would
        // be left wherever the scrub happened to end, with its newest bubble
        // stranded behind the bar.
        guard !collectionView.isTracking else {
            // The distance measured NOW is already contaminated by the scrub in
            // progress, and it grows with every layout pass the drag triggers.
            // What is owed back is where the reader was when they touched down.
            deferredTailDistance = dragStartTailDistance ?? distanceFromTail
            return
        }
        let translated = min(
            max(offsetBefore + delta, -collectionView.adjustedContentInset.top),
            maxContentOffsetY
        )
        // The translation alone is not enough when the travel gets clamped: a
        // conversation shorter than the viewport is top-aligned and has only a
        // few points of scroll range, so translating it by a whole keyboard
        // height slams it against the TOP of that range and files the last
        // bubble behind the compose bar — which is what the bar growing a
        // sticker strip made visible. Holding the reader's distance from the
        // tail as a floor keeps a tail-pinned transcript tail-pinned no matter
        // how little room it has, while someone parked deep in history still
        // rides the bar 1:1.
        collectionView.contentOffset.y = max(
            translated,
            max(-collectionView.adjustedContentInset.top, maxContentOffsetY - distanceFromTail)
        )
    }

    /// Applies the pin an in-flight drag postponed. Called when the list comes
    /// to rest; no-op unless a clearance change actually happened under a
    /// finger, so ordinary scrolling never gets corrected.
    private func settleDeferredClearancePin() {
        guard let distance = deferredTailDistance, !collectionView.isTracking else { return }
        deferredTailDistance = nil
        dragStartTailDistance = nil

        // Only transcripts with no room to spare. When the list has real travel
        // a downward drag IS a scroll into history that the dismissal merely
        // rode along with, and snapping back would steal the gesture. Below one
        // bar's worth of travel there is no reading position to steal — just a
        // newest bubble that would otherwise sit behind the composer.
        let minOffset = -collectionView.adjustedContentInset.top
        guard maxContentOffsetY - minOffset < inputBar.bounds.height else { return }

        let target = max(minOffset, maxContentOffsetY - distance)
        guard target > collectionView.contentOffset.y + 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    /// The largest `contentOffset.y` the transcript can hold with its current
    /// insets — the tail. `adjustedContentInset.bottom` already carries the
    /// compose-bar clearance, so this grows with the keyboard, and it never
    /// reports less than the minimum for content shorter than the viewport.
    private var maxContentOffsetY: CGFloat {
        let insets = collectionView.adjustedContentInset
        let reachable = collectionView.contentSize.height + insets.bottom - collectionView.bounds.height
        return max(-insets.top, reachable)
    }

    // MARK: - Reply-swipe scroll lock

    /// Hands scrolling back to the transcript. Idempotent, and safe to call
    /// from teardown paths that don't know whether a swipe was in flight.
    private func unlockTranscriptScrolling() {
        guard replySwipingCell != nil else { return }
        replySwipingCell = nil
        collectionView.isScrollEnabled = true
    }
}

// MARK: - Bubble context menu (haptic long-press)

extension ConversationViewController: UICollectionViewDelegate {
    /// The collection's native `UIContextMenuInteraction` seam, per item.
    /// Gated three ways: never inside a peek (`.preview` already lives under
    /// an active context interaction), one bubble at a time, and only when
    /// the press lands on the bubble itself — the row is full-width, but its
    /// empty flank is not a press target (Messages behavior).
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        // A fresh long-press supersedes any active text selection.
        endTextSelection()
        guard mode == .full, indexPaths.count == 1, let indexPath = indexPaths.first,
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              cell.bubbleContains(collectionView.convert(point, to: cell)),
              let id = dataSource.itemIdentifier(for: indexPath),
              let row = rowsByID[id]
        else { return nil }
        let configuration = UIContextMenuConfiguration(
            identifier: id as NSString,
            actionProvider: { [weak self] _ in self?.messageMenu(for: row) }
        )
        // Which SIDE of the bubble the menu lands on is the system's call
        // (the arbiter picks the roomier side; no public placement API as of
        // iOS 26 — audited UIContextMenuConfiguration/Interaction headers).
        // What we CAN pin is the hierarchy: `.fixed` keeps Reply→…→Delete
        // reading top-down in both placements, where `.automatic` may
        // reorder relative to the press point.
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    /// The lift: hand the system the bubble-shaped targeted preview instead
    /// of the default full-cell platter. The rest of the transcript blurs
    /// behind it automatically.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        (collectionView.cellForItem(at: indexPath) as? MessageCell)?.bubblePreview()
    }

    /// Same shape on the way back down, so the settle animation lands the
    /// bubble exactly into its row (nil lets the system cross-fade if the
    /// cell scrolled out from under an open menu).
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        (collectionView.cellForItem(at: indexPath) as? MessageCell)?.bubblePreview()
    }

    /// Standard messaging actions. Reply enters the compose reply state; Copy
    /// is complete (pasteboard, from the row the menu was built for); Forward
    /// remains an honest stub; Delete gates behind a native confirmation.
    /// Destructive action sits in its own inline section, per system menus.
    private func messageMenu(for row: MessageRowModel) -> UIMenu {
        let reply = UIAction(
            title: "Reply",
            image: UIImage(systemName: "arrowshape.turn.up.left")
        ) { [weak self] _ in self?.viewModel.beginReply(to: row.id) }
        let copy = UIAction(
            title: "Copy",
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in UIPasteboard.general.string = row.body }
        let selectText = UIAction(
            title: "Select Text",
            image: UIImage(systemName: "text.magnifyingglass")
        ) { [weak self] _ in self?.beginTextSelection(for: row.id) }
        let forward = UIAction(
            title: "Forward",
            image: UIImage(systemName: "arrowshape.turn.up.right")
        ) { [weak self] _ in self?.viewModel.perform(.forward, on: row.id) }
        let delete = UIAction(
            title: "Delete",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in self?.confirmDelete(row.id) }
        return UIMenu(children: [reply, copy, selectText, forward, UIMenu(options: .displayInline, children: [delete])])
    }

    /// Native destructive confirmation before removing a message — an action
    /// sheet with the single "Delete Message" affordance, mirroring Messages.
    /// Deferred a runloop so it presents cleanly after the context menu's own
    /// dismissal animation, never on top of it.
    private func confirmDelete(_ messageID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Delete Message", style: .destructive) { [weak self] _ in
                self?.viewModel.deleteMessage(messageID)
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            // iPad: anchor the popover to the message's bubble if it's on screen.
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = self.collectionView
                if let indexPath = self.dataSource.indexPath(for: messageID),
                   let cell = self.collectionView.cellForItem(at: indexPath) {
                    popover.sourceRect = cell.frame
                } else {
                    popover.sourceRect = CGRect(
                        x: self.collectionView.bounds.midX, y: self.collectionView.bounds.midY,
                        width: 0, height: 0
                    )
                }
            }
            self.present(sheet, animated: true)
        }
    }

    /// Jumps to a message by id — the tap target of a reply's quoted preview —
    /// and, once the scroll settles, flashes the destination bubble. The flash
    /// waits for `scrollViewDidEndScrollingAnimation` because a big jump's
    /// destination cell isn't realized until the animation lands; a fallback
    /// timer covers the case where the target was already on screen (no scroll,
    /// so no end-animation callback fires).
    private func scrollToMessage(_ id: String, highlight: Bool) {
        guard let indexPath = dataSource.indexPath(for: id) else { return }
        pendingFlashID = highlight ? id : nil
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
        guard highlight else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pendingFlashID == id else { return }
            self.pendingFlashID = nil
            self.flashMessage(id)
        }
    }

    private func flashMessage(_ id: String) {
        guard let indexPath = dataSource.indexPath(for: id) else { return }
        (collectionView.cellForItem(at: indexPath) as? MessageCell)?.flashHighlight()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let id = pendingFlashID else { return }
        pendingFlashID = nil
        flashMessage(id)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // Scrolling dismisses a text selection (Messages behavior).
        endTextSelection()
        // Only a reading position, not a promise to restore it: it is handed
        // back exclusively when the keyboard moved under this same finger.
        dragStartTailDistance = max(0, maxContentOffsetY - collectionView.contentOffset.y)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        settleDeferredClearancePin()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleDeferredClearancePin()
    }
}

// MARK: - Select text

extension ConversationViewController: UIGestureRecognizerDelegate {
    /// Enters interactive text selection on a bubble — the context menu's
    /// "Select Text". Deferred a runloop so it starts cleanly after the menu's
    /// own dismissal, then installs the tap-outside dismissal.
    private func beginTextSelection(for id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let indexPath = self.dataSource.indexPath(for: id),
                  let cell = self.collectionView.cellForItem(at: indexPath) as? MessageCell
            else { return }
            self.endTextSelection()
            cell.beginTextSelection()
            self.textSelectionCell = cell
            self.collectionView.addGestureRecognizer(self.textSelectionDismissTap)
        }
    }

    private func endTextSelection() {
        guard textSelectionCell != nil else { return }
        textSelectionCell?.endTextSelection()
        textSelectionCell = nil
        collectionView.removeGestureRecognizer(textSelectionDismissTap)
    }

    @objc private func handleTextSelectionDismissTap() {
        endTextSelection()
    }

    /// The dismiss tap fires only for taps that land OUTSIDE the selected
    /// bubble and inside the transcript — taps on the bubble/handles go to the
    /// text view, and the floating Copy/Share callout (a separate view tree,
    /// not a collection-view descendant) is ignored so it stays interactive.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === textSelectionDismissTap, let cell = textSelectionCell else { return true }
        guard let touched = touch.view, touched.isDescendant(of: collectionView) else { return false }
        return !cell.bounds.contains(touch.location(in: cell))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Quoted-reply tap

extension ConversationViewController: MessageCellDelegate {
    /// Tapping a bubble's quoted preview jumps to the original message.
    func messageCell(_ cell: MessageCell, didTapQuotedMessage id: String) {
        scrollToMessage(id, highlight: true)
    }

    /// Swiping a bubble past the threshold enters the reply compose state —
    /// same seam as the context-menu Reply.
    func messageCell(_ cell: MessageCell, didSwipeToReply id: String) {
        viewModel.beginReply(to: id)
    }

    /// Freeze the transcript for the drag. `isScrollEnabled = false` does two
    /// jobs at once: it stops the vertical component of a diagonal drag from
    /// reaching the scroll pan (the diagonal-drift bug), and it CANCELS any
    /// scroll already in flight, so a horizontal swipe that starts mid-scroll
    /// takes the gesture over outright instead of sharing the finger.
    func messageCellDidBeginReplySwipe(_ cell: MessageCell) {
        // A text selection and a reply drag are mutually exclusive modes.
        endTextSelection()
        replySwipingCell = cell
        collectionView.isScrollEnabled = false
    }

    /// Only the cell that took the lock may release it — a recycled cell's late
    /// end call must not unfreeze a swipe that has since begun on another row.
    func messageCellDidEndReplySwipe(_ cell: MessageCell) {
        guard replySwipingCell === cell else { return }
        unlockTranscriptScrolling()
    }
}
