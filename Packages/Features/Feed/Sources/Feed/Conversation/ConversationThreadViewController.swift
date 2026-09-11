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
/// header and footer frost are the same `ProgressiveFrostView` bands, and the
/// footer is `SnapFooterToolbar` with the emote strip where a post shows its
/// music. What a conversation adds is a chat's reading order: oldest at the
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
    private let accessory: (any ConversationThreadAccessory)?
    private let imagePipeline: ImagePipeline
    private let wallet: WalletStore?
    private let makeWalletSheet: (@MainActor () -> UIViewController)?

    private let headerPolicy = HeaderPolicy()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let contextMenu = ThreadRowContextMenu()
    private let composeBar = CommentsInputBar()
    private let headerFrost = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.headerFrostMaskColors,
        maskLocations: SnapCommentsLayout.headerFrostMaskLocations
    )
    private let composerBackdrop = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.footerFrostMaskColors,
        maskLocations: SnapCommentsLayout.footerFrostMaskLocations
    )
    private var headerFrostHeight: NSLayoutConstraint?
    private let refreshControl = UIRefreshControl()
    private let statusLabel = UILabel()
    private let peerPill = SnapAuthorIdentityView()
    private let walletBadge = WalletBadgeButton()
    private var walletBadgeItem: UIBarButtonItem?
    private let walletObservers = NotificationObserverTokenBag()

    private var phase: ConversationThreadPhase = .loading
    private var messagesByID: [String: ConversationThreadMessage] = [:]
    private var peer = ConversationThreadPerson(id: nil, name: "", avatarURL: nil)
    private var viewer = ConversationThreadPerson(id: nil, name: "You", avatarURL: nil)
    private var hasRenderedContent = false
    private var hasEstablishedClearance = false
    private var newestID: String?
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
        accessory: (any ConversationThreadAccessory)?,
        imagePipeline: ImagePipeline,
        wallet: WalletStore?,
        makeWalletSheet: (@MainActor () -> UIViewController)?
    ) {
        self.driver = driver
        self.mode = mode
        self.prefill = prefill
        self.accessory = accessory
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
        configureHeaderFrost()
        if mode == .full {
            configureComposer()
            configureToolbar()
            contextMenu.install(on: collectionView)
            contextMenu.menuProvider = { [weak self] indexPath in self?.menu(at: indexPath) }
        }
        configureNavigationItem()
        configureStatusLabel()
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
        // Before the bars first lay these out, not only after: a budget that
        // arrives late is a bar that has already collapsed into a `•••`.
        fitTrailingRun()
        fitAccessory()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Materials in a window only — built in init they stall headless CI.
        for band in [headerFrost, composerBackdrop] where band.superview != nil && band.effect == nil {
            band.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        contextMenu.endTextSelection()
        guard mode == .full else { return }
        // Taken away on the way out, or the inbox inherits an empty bar.
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        headerFrostHeight?.constant = SnapCommentsLayout.commentsTopInset(topInset: view.safeAreaInsets.top)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard mode == .full else {
            // A peek's platter settles its size over several passes; keep the
            // tail pinned until it does, never while a finger is down.
            if collectionView.bounds.size != lastPreviewSize {
                lastPreviewSize = collectionView.bounds.size
                if hasRenderedContent, !collectionView.isTracking { scrollToBottom(animated: false) }
            }
            return
        }
        fitAccessory()
        syncBottomClearance()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInset.top = SnapCommentsLayout.streamTopBreath
        collectionView.delegate = self
        if mode == .preview {
            // The tail never sits flush on the platter's edge.
            collectionView.contentInset.bottom = Spacing.md
        } else {
            refreshControl.addAction(UIAction { [weak self] _ in self?.driver.refresh() }, for: .valueChanged)
            collectionView.refreshControl = refreshControl
            // A bare tap on the stream retires the keyboard, as on the post.
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
            cell.configure(
                symbolName: "bubble.left.and.bubble.right",
                title: "No messages yet",
                subtitle: "Say hi 👋",
                height: self?.emptyPageHeight() ?? SnapCommentsLayout.emptyPageMinimumHeight
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

    private func configureHeaderFrost() {
        headerFrost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        headerFrost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerFrost)
        let height = headerFrost.heightAnchor.constraint(
            equalToConstant: SnapCommentsLayout.commentsTopInset(topInset: view.safeAreaInsets.top)
        )
        headerFrostHeight = height
        NSLayoutConstraint.activate([
            headerFrost.topAnchor.constraint(equalTo: view.topAnchor),
            headerFrost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerFrost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])
    }

    /// The text page's composer, at the text page's resting place: just above
    /// the footer when the keyboard is down, riding the keyboard when it is up.
    private func configureComposer() {
        composeBar.showsIdleUtilityFaces = true
        composeBar.defaultPlaceholder = "Message…"
        composeBar.draftText = prefill
        composeBar.onSend = { [weak self] text in self?.driver.send(text) }
        // The reply state's natural exit, as on the post: the keyboard retired
        // over an empty field.
        composeBar.onIdleDismiss = { [weak self] in self?.driver.cancelReply() }
        composeBar.onVoiceNote = { [weak self] in
            self?.presentNotice("Voice Messages", "Voice messages aren't available yet.")
        }
        composeBar.onBoost = { [weak self] _ in
            self?.presentNotice("Boost", "Boosting a conversation isn't available yet.")
        }

        composerBackdrop.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        composerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBackdrop)
        view.addSubview(composeBar)
        // The keyboard guide measured from the screen's edge, so the resting
        // constraint — the safe area, which the footer toolbar inflates — is
        // what holds the bar while the keyboard is down, and the inequality
        // lifts it the moment the keyboard rises past it.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let ceiling = composeBar.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm
        )
        let rest = composeBar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.sm
        )
        rest.priority = .defaultHigh
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.lg),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.lg),
            ceiling,
            rest,
            composerBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composerBackdrop.topAnchor.constraint(
                equalTo: composeBar.topAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
        ])
    }

    /// The post's footer, with the emote strip where the music would be.
    private func configureToolbar() {
        guard let accessory else { return }
        accessory.onInsertText = { [weak self] text in self?.composeBar.insertIntoComposer(text) }
        let save = SnapFooterToolbar.makeSaveButton()
        save.addAction(UIAction { [weak self] _ in
            self?.presentNotice("Save", "Saving conversations isn't available yet.")
        }, for: .primaryActionTriggered)
        let more = SnapFooterToolbar.makeMoreButton(menu: UIMenu(children: [
            UIAction(title: "View Profile", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                self?.driver.didTapIdentity()
            },
        ]))
        toolbarItems = SnapFooterToolbar.items(
            leading: accessory.view,
            bookmark: save,
            repost: SnapFooterToolbar.makeRepostButton(),
            more: more
        )
    }

    private func configureNavigationItem() {
        // The text page's bar: transparent, so the header frost is the only
        // band, and set per item so the inbox behind keeps its own.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        // `title` still feeds back labels; the centre stays empty.
        navigationItem.titleView = UIView()

        peerPill.setFollowHidden(true)
        peerPill.setOverMedia(false)
        peerPill.onAuthorTapped = { [weak self] _ in self?.driver.didTapIdentity() }
        var items = [UIBarButtonItem(customView: peerPill)]
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
            items += [.fixedSpace(Spacing.sm), item]
        }
        navigationItem.rightBarButtonItems = items
    }

    private func configureStatusLabel() {
        statusLabel.font = .preferredFont(forTextStyle: .body)
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
    }

    // MARK: - Render

    private func render(_ phase: ConversationThreadPhase) {
        self.phase = phase
        refreshControl.endRefreshing()
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
        applySnapshot(animated: hasRenderedContent)
        guard case .content(let messages) = phase else { return }
        hasRenderedContent = true

        let newest = messages.last
        let newestChanged = newest?.id != newestID
        newestID = newest?.id
        if isFirstContent {
            // Twice: estimated heights refine once the first rows realize, and
            // the first pass lands short of the tail.
            scrollToBottom(animated: false)
            DispatchQueue.main.async { [weak self] in self?.scrollToBottom(animated: false) }
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
        cell.row.onReplyTap = mode == .full ? { [weak self] in self?.driver.beginReply(to: messageID) } : nil
        if let quote = message.quote {
            cell.setQuote((quote.author, quote.snippet))
            cell.onQuoteTap = { [weak self] in self?.scrollToMessage(quote.messageID) }
        } else {
            cell.setQuote(nil)
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

    /// Deleting asks first. Presented a turn later so it lands after the
    /// context menu's own dismissal rather than racing it.
    private func confirmDelete(_ messageID: String) {
        DispatchQueue.main.async { [weak self] in
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

    private func scrollToMessage(_ messageID: String) {
        guard let indexPath = dataSource.indexPath(for: .message(messageID)) else { return }
        pendingFlashID = messageID
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
        // Already on screen: no scroll animation will end to fire the flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.flashPending() }
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
        let composerTop = composeBar.frame.minY
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
    private func fitTrailingRun() {
        let bar = navigationController?.navigationBar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }
        let itemPadding: CGFloat = 18
        var budget = bar - 16 * 2 - (36 + itemPadding) - itemPadding
        if walletBadgeItem != nil {
            let badge = walletBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            budget -= badge + itemPadding + Spacing.sm
        }
        peerPill.setWidthBudget(budget)
    }

    private func fitAccessory() {
        let bar = navigationController?.toolbar.bounds.width ?? view.bounds.width
        guard bar > 0 else { return }
        accessory?.setPreferredWidth(SnapFooterToolbar.leadingWidthBudget(barWidth: bar))
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

    private func emptyPageHeight() -> CGFloat {
        let insets = collectionView.adjustedContentInset
        let height = collectionView.bounds.height > 0 ? collectionView.bounds.height : view.bounds.height
        return SnapCommentsLayout.emptyPageHeight(availableHeight: height - insets.top - insets.bottom)
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
}

extension ConversationThreadViewController: UICollectionViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        contextMenu.endTextSelection()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        flashPending()
    }
}
