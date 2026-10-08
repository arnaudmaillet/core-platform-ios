import CoreModels
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
    private let wallet: WalletStore?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

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
    private let statusLabel = UILabel()
    /// Under the bar while older history is on its way (#600): pinned to the
    /// screen rather than to the content, so it is where the reader is
    /// looking — at the top — whatever the scroll. Turns only while a page
    /// is out; an idle spinner redraws the screen every frame (#580).
    private let olderSpinner = UIActivityIndicatorView(style: .medium)
    private let peerPill = SnapAuthorIdentityView()
    private let walletBadge = WalletBadgeButton()
    private var walletBadgeItem: UIBarButtonItem?
    private let walletObservers = NotificationObserverTokenBag()

    private var phase: ConversationThreadPhase = .loading
    private var messagesByID: [String: ConversationThreadMessage] = [:]
    private var peer = ConversationThreadPerson(id: nil, name: "", avatarURL: nil)
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
        wallet: WalletStore?,
        makeWalletSheet: (@MainActor () -> UIViewController)?
    ) {
        self.driver = driver
        self.mode = mode
        self.prefill = prefill
        self.imagePipeline = imagePipeline
        self.wallet = wallet
        self.makeWalletSheet = makeWalletSheet
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
        // After the clearance, in the same pass: see `pinToTail`.
        if owesTailPin { pinToTail() }
    }

    // MARK: - Setup

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInset.top = SnapCommentsLayout.streamTopBreath
        // No effect under the bar: the rows run up under the pills untouched — see
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
        return UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: Spacing.lg, bottom: 0, trailing: Spacing.lg
            )
            if policy.daySections {
                // The day chip, pinned while its day's rows scroll under it.
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)
                    ),
                    elementKind: DayPillHeaderView.elementKind,
                    alignment: .top
                )
                header.pinToVisibleBounds = true
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
            header.configure(title: DayTitleFormatter.title(for: day))
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
        // `title` still feeds back labels; the centre stays empty.
        navigationItem.titleView = UIView()

        peerPill.setFollowBadge(.none)
        peerPill.setOverMedia(false)
        peerPill.onAuthorTapped = { [weak self] _ in self?.driver.didTapIdentity() }
        // The pill is the toolbar's (#671); a preview (no toolbar) keeps it
        // in the bar.
        var items = pillRidesToolbar ? [] : [UIBarButtonItem(customView: peerPill)]
        if mode == .full, wallet != nil {
            walletBadge.isUserInteractionEnabled = makeWalletSheet != nil
            if makeWalletSheet != nil {
                walletBadge.addAction(UIAction { [weak self] _ in
                    self?.presentWalletSheet()
                }, for: .primaryActionTriggered)
            }
            let item = UIBarButtonItem(customView: walletBadge)
            walletBadgeItem = item
            // A grown count needs a FRESH item — re-adding the same one hands
            // the bar the same frozen wrapper (the feed's measured finding).
            walletBadge.onFittedWidthChange = { [weak self] in self?.refreshWalletItem() }
            refreshWalletBadge()
            walletObservers.tokens = [
                NotificationCenter.default.addObserver(
                    forName: WalletStore.didChangeNotification, object: wallet, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshWalletBadge() }
                },
            ]
            items += items.isEmpty ? [item] : [.fixedSpace(Spacing.sm), item]
        }
        navigationItem.rightBarButtonItems = items
    }

    private func configureStatusLabel() {
        statusLabel.font = .appFont(forTextStyle: .body)
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

    private func bindDriver() {
        driver.onPhaseChange = { [weak self] phase in self?.render(phase) }
        driver.onPeerChange = { [weak self] person in self?.adoptPeer(person) }
        driver.onViewerChange = { [weak self] person in self?.adoptViewer(person) }
        driver.onSendingChange = { [weak self] sending in self?.composeBar.isSending = sending }
        driver.onReplyStateChange = { [weak self] draft in self?.renderReply(draft) }
        driver.onActionNotice = { [weak self] title, message in self?.presentNotice(title, message) }
        driver.onPinnedChange = { [weak self] pinned in self?.renderPinned(pinned) }
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
        self.phase = phase
        switch phase {
        case .loading:
            statusLabel.isHidden = true
        case .failed(let message):
            statusLabel.text = message
            statusLabel.isHidden = hasRenderedContent
        case .content(let messages):
            statusLabel.isHidden = true
            messagesByID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        let isFirstContent = !hasRenderedContent
        // Older history landing above (#600): applied without animation and
        // with the message under the reader's eye held where it is.
        let anchor = olderHistoryAnchor(for: phase)
        applySnapshot(animated: hasRenderedContent && anchor == nil)
        if let anchor { hold(anchor) }
        guard case .content(let messages) = phase else { return }
        hasRenderedContent = true
        oldestID = messages.first?.id

        let newest = messages.last
        let newestChanged = newest?.id != newestID
        newestID = newest?.id
        if isFirstContent {
            pinToTail()
        } else if newestChanged, newest?.isMine == true || isNearBottom {
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
            // Rows already on screen re-render in place: a name, a face or a
            // quote can change under a message whose identity did not.
            let surviving = snapshot.itemIdentifiers.filter { previous.indexOfItem($0) != nil }
            snapshot.reconfigureItems(surviving)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func configure(_ cell: ThreadRowCell, messageID: String) {
        guard let message = messagesByID[messageID] else { return }
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
                metaText: Self.timeFormatter.string(from: message.sentAt),
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
        cell.mediaView.onTap = message.media == nil ? nil : { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.tapMedia(of: messageID, in: cell)
        }
    }

    private func adoptPeer(_ person: ConversationThreadPerson) {
        peer = person
        title = person.name
        peerPill.setPerson(
            id: person.id, name: person.name, meta: "", avatarURL: person.avatarURL, pipeline: imagePipeline
        )
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
    /// back button, and the wallet badge when there is one. Measured, and
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
        if walletBadgeItem != nil {
            let badge = walletBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            budget -= badge + itemPadding + Spacing.sm
        }
        peerPill.setWidthBudget(budget)
    }

    private func refreshWalletBadge() {
        guard let wallet else { return }
        let snapshot = wallet.snapshot()
        walletBadge.update(
            balance: snapshot.balance,
            claimAvailable: makeWalletSheet != nil && snapshot.claimAvailable,
            claimProgress: snapshot.claimCountdown.map {
                WalletBadgeButton.ClaimProgress(fraction: $0.fraction, remaining: $0.remaining)
            }
        )
    }

    private func refreshWalletItem() {
        guard let old = walletBadgeItem,
              var items = navigationItem.rightBarButtonItems,
              let index = items.firstIndex(of: old) else { return }
        let fresh = UIBarButtonItem(customView: walletBadge)
        walletBadgeItem = fresh
        items[index] = fresh
        navigationItem.rightBarButtonItems = items
        fitTrailingRun()
    }

    private func presentWalletSheet() {
        guard let makeWalletSheet, presentedViewController == nil else { return }
        present(makeWalletSheet(), animated: true)
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
