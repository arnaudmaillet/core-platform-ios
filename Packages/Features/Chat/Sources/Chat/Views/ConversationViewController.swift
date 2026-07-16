import DesignSystem
import UIKit

/// The conversation thread, Telegram-grade on stock UIKit: a compositional-
/// layout collection view with diffable snapshots and self-sizing bubble
/// cells, day chips pinned per section, and a floating glass compose bar
/// docked to the keyboard through `keyboardLayoutGuide`.
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
    private let identityView = ConversationIdentityView()
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    private var dataSource: UICollectionViewDiffableDataSource<TranscriptDay, String>!
    private var rowsByID: [String: MessageRowModel] = [:]
    private var newestRowID: String?
    private var hasRenderedContent = false
    /// Preview only: the platter can resize while animating in, stranding
    /// the one-shot tail scroll mid-history — tracked to re-pin on change.
    private var lastPreviewLayoutSize = CGSize.zero

    init(viewModel: ConversationViewModel, mode: Mode = .full) {
        self.viewModel = viewModel
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        // A thread takes the full screen height: the system hides the tab bar
        // with the push and restores it on pop. Safe here — unlike the feed's
        // manually managed bar (see `FeedFlowCoordinator`), a thread pops via
        // the standard gesture, which this flag's choreography scrubs with.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Conversation"
        view.backgroundColor = .systemBackground
        configureNavigationItem()
        configureCollectionView()
        configureStatusViews()
        if mode == .full {
            configureInputBar()
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillShow),
                name: UIResponder.keyboardWillShowNotification, object: nil
            )
        }

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onSendingChange = { [weak self] sending in self?.inputBar.isSending = sending }
        viewModel.onTitleChange = { [weak self] name in
            guard let self else { return }
            // `title` still carries the name (it feeds pushed screens' back
            // labels); the visible identity lives in the trailing pill.
            self.title = name
            self.identityView.setIdentity(
                name: name,
                monogram: ConversationDisplayModel.monogram(name)
            )
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
        // The transcript scrolls under the floating bar: keep a clearance
        // inset matching the bar's overlap beyond the bottom safe area. Runs
        // on every keyboard-guide-driven pass, so it tracks docking too.
        let overlap = max(0, view.bounds.height - inputBar.frame.minY - view.safeAreaInsets.bottom)
        let clearance = overlap + Spacing.md
        if collectionView.contentInset.bottom != clearance {
            collectionView.contentInset.bottom = clearance
            collectionView.verticalScrollIndicatorInsets.bottom = clearance
        }
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
        collectionView.pin(to: view)

        if mode == .full {
            refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
            collectionView.refreshControl = refreshControl
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
            if let row = self?.rowsByID[id] { cell.configure(with: row) }
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
        // The bottom mirror of the nav bar's soft scroll edge: the system
        // draws the same progressive fade-blur behind this container's
        // region, shaped around its glass elements — and because the effect
        // is bound to the VIEW, it tracks every keyboard-guide move (dock,
        // undock, interactive dismissal scrubs) with no geometry code here.
        let edgeEffect = UIScrollEdgeElementContainerInteraction()
        edgeEffect.scrollView = collectionView
        edgeEffect.edge = .bottom
        inputBar.addInteraction(edgeEffect)
        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.md),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.md),
            // The dock: the guide tracks the keyboard, including interactive
            // dismissal scrubs, so the bar rides it with no keyboard math.
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Spacing.sm)
        ])
        inputBar.onSend = { [weak self] text in self?.viewModel.send(text) }
        // Honest seam: chat.v1 SendMessage is text-only today. The affordance
        // ships per the design spec; the picker wires in with the media plane.
        inputBar.onAttachMedia = { [weak self] in
            let alert = UIAlertController(
                title: "Media Messages",
                message: "Sending photos and videos isn't available yet.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
    }

    private func configureStatusViews() {
        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
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
            if !refreshControl.isRefreshing { spinner.startAnimating() }
            collectionView.isHidden = true
            statusLabel.isHidden = true
        case .content(let models):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            collectionView.isHidden = false
            statusLabel.text = "No messages yet. Say hi 👋"
            statusLabel.isHidden = !models.isEmpty
            applyTranscript(for: models)
        case .failed(let message):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            collectionView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }

    private func applyTranscript(for models: [MessageDisplayModel]) {
        let sections = ChatTranscript.build(from: models)

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
        // but never yank a reader who has scrolled up into history.
        let newestID = snapshot.itemIdentifiers.last
        let isFirstRender = !hasRenderedContent
        let shouldFollow = isFirstRender || (newestID != newestRowID && isNearBottom)

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

    /// Keyboard rising while the tail is on screen keeps the tail pinned
    /// (Telegram behavior); deep in history, the view stays put.
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard isNearBottom else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scrollToBottom(animated: true)
        }
    }
}
