import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import MediaCore
import UIKit

/// The wallet sheet behind the balance badges (map, feed, profile): the two
/// currencies, the claim streak and today's earnings, the viewer's stakes, and
/// the Claim button.
///
/// # The economy it shows (`dev/economy/`, charter V5.3)
///   • **Points** (currency A, the red heart) — curation capacity: claimed
///     here, spent by STAKING on posts;
///   • **Gems** (currency B, the diamond) — earned-only: what a stake pays
///     once it SETTLES, if it turned out to carry information. Settlement is
///     deferred by design, so a stake is ACTIVE for a while before it has an
///     outcome.
///
/// # Anatomy, top to bottom
///   • the SUMMARY — Points and Gems side by side in big type, then the
///     streak and today's earnings, bare on the page (`WalletSummaryView`);
///   • ACTIVE STAKES — each post, the points on it, and how long until it
///     settles;
///   • SETTLED — each post and what it earned in gems, or "No reward";
///   • the CLAIM button, pinned to the sheet's bottom whatever is scrolled,
///     over a blur the list passes under.
///
/// # Small first, then large, then gone
/// The sheet opens SMALL: the summary and the first two stakes at most — the
/// glance-and-claim surface. Scrolling the list up grows it to LARGE (the
/// sheet's own `prefersScrollingExpandsWhenScrolledToEdge`). And once large it
/// FORGETS the small detent: a drag down from the top closes the sheet in one
/// motion rather than parking it halfway (26 September 2026: "elle ne repasse
/// pas par le state petit, elle se ferme directement"). Once the summary has
/// scrolled away it collapses into a compact bar under the grabber
/// (`WalletCompactBar`), so the list is never read without the balances.
///
/// Everything derives from one `WalletSnapshot` and one `stakes()` reading per
/// refresh; the only per-second work is the claim countdown and the active
/// stakes' "settles in" lines.
final class WalletClaimViewController: UIViewController {
    /// Resolves stake targets to their posts — the Feed feature's, handed in
    /// by the composition root (`AppContainer.makeWalletSheet`).
    typealias PostLookup = @MainActor ([PostID]) async -> [PostID: FeedEntry]

    private let wallet: WalletStore
    private let lookUpPosts: PostLookup?
    private let imagePipeline: ImagePipeline?

    private nonisolated enum Section: Hashable { case summary, active, settled }
    private nonisolated enum Item: Hashable {
        case summary
        case stake(String)
        case noActiveStakes
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private weak var summaryCell: WalletSummaryCell?
    private let compactBar = WalletCompactBar()
    private let claimButton = UIButton(configuration: .prominentGlass())
    /// The blur the list passes under at the foot of the sheet, behind the
    /// button. ⚠️ Not an opaque band: the glass button samples what lies
    /// beneath it straight through an opaque sibling (measured with a red
    /// band — the rows sat on top), so the list is DESIGNED to be there, and
    /// dissolves on its way under.
    private let bottomBlur = WalletEdgeBlurView(edge: .bottom, setsOwnEffect: true)

    private var snapshot: WalletSnapshot
    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: FeedEntry] = [:]
    private var requestedPosts: Set<PostID> = []

    private var countdownTimer: Timer?
    private let walletObservers = WalletObserverTokenBag()

    /// The SMALL detent's height, measured from the laid-out list — a stored
    /// number, because a detent resolver must read nothing that could load a
    /// view.
    private var smallDetentHeight: CGFloat = 460
    private static let smallDetent = UISheetPresentationController.Detent.Identifier("wallet.small")
    /// How many stake rows the small detent shows under the summary.
    private static let smallDetentRows = 2

    private var buttonLeading: NSLayoutConstraint?
    private var buttonTrailing: NSLayoutConstraint?
    private var buttonBottom: NSLayoutConstraint?
    private var buttonMargin: CGFloat = WalletSheetMetrics.sideMargin
    private var appliedSheetRadius: CGFloat = 0

    private static let compactBarHeight: CGFloat = 44
    /// Room under the grabber before the summary starts.
    private static let topInset: CGFloat = Spacing.xl

    init(wallet: WalletStore, lookUpPosts: PostLookup? = nil, imagePipeline: ImagePipeline? = nil) {
        self.wallet = wallet
        self.lookUpPosts = lookUpPosts
        self.imagePipeline = imagePipeline
        self.snapshot = wallet.snapshot()
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [
                .custom(identifier: Self.smallDetent) { [weak self] _ in self?.smallDetentHeight ?? 460 },
                .large(),
            ]
            // ⚠️ OPENS SMALL; a scroll up grows it (see the type's note).
            sheet.selectedDetentIdentifier = Self.smallDetent
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = WalletSheetMetrics.claimHeight / 2 + WalletSheetMetrics.sideMargin
            sheet.delegate = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The grouped page — For You's and Profile's — so the stake cards are
        // white ON it rather than grey on white.
        view.backgroundColor = Surface.page
        buildCollection()
        buildChrome()

        walletObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        refresh()

        // Measured NOW, before the sheet asks its first detent: a guess here
        // would present at the guess and then jump to the answer.
        view.layoutIfNeeded()
        updateSmallDetent()

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // Every hook below waits for the sheet to have LANDED (in a window,
        // no transition running), not for a guessed delay.
        let landed: @MainActor () -> Bool = { [weak self] in
            guard let self else { return true }
            return view.window != nil && transitionCoordinator == nil
        }
        // `-wallet-demo-claim`: fires the Claim button once the sheet is up —
        // the real claim path minus the finger. Pair with `-open-wallet
        // -wallet-claim-ready`.
        if arguments.contains("-wallet-demo-claim") {
            QAWait.until("-wallet-demo-claim", landed) { [weak self] in self?.claimTapped() }
        }
        // `-wallet-sheet-large`: grows the sheet to LARGE, the state a scroll
        // up reaches, so it can be screenshotted.
        if arguments.contains("-wallet-sheet-large") {
            QAWait.until("-wallet-sheet-large", landed) { [weak self] in
                guard let sheet = self?.sheetPresentationController else { return }
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
                // The delegate is not told about a programmatic change.
                self?.forgetSmallDetentOnceLarge()
            }
        }
        // `-wallet-sheet-scroll <pt>`: scrolls the list, so the collapsed
        // header can be screenshotted. Pair with `-wallet-sheet-large`.
        if let index = arguments.firstIndex(of: "-wallet-sheet-scroll"), index + 1 < arguments.count,
           let offset = Double(arguments[index + 1]) {
            QAWait.until("-wallet-sheet-scroll", landed) { [weak self] in
                guard let collection = self?.collectionView else { return }
                collection.setContentOffset(
                    CGPoint(x: 0, y: offset - collection.adjustedContentInset.top), animated: true
                )
            }
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyDeviceCornerRadius()
        updateSmallDetent()
        updateCompactBar()
    }

    // MARK: - Layout

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, _ in
            let section = self?.dataSource?.sectionIdentifier(for: index) ?? .summary
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)
            ))
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)),
                subitems: [item]
            )
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.interGroupSpacing = Spacing.sm
            let margin = WalletSheetMetrics.sideMargin
            layoutSection.contentInsets = NSDirectionalEdgeInsets(
                top: section == .summary ? 0 : Spacing.xs, leading: margin, bottom: 0, trailing: margin
            )
            if section != .summary {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                    elementKind: WalletSectionHeader.kind, alignment: .top
                )
                layoutSection.boundarySupplementaryItems = [header]
            }
            return layoutSection
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = UIEdgeInsets(top: Self.topInset, left: 0, bottom: Spacing.lg, right: 0)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // To the sheet's foot: the list passes UNDER the Claim button's
            // blur rather than ending above it.
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let summaryRegistration = UICollectionView.CellRegistration<WalletSummaryCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.summary.configure(with: snapshot)
            summaryCell = cell
        }
        let stakeRegistration = UICollectionView.CellRegistration<WalletStakeCell, Item> { [weak self] cell, _, item in
            guard let self, case .stake(let id) = item, let stake = stakesByID[id] else { return }
            cell.configure(
                stake: stake, entry: entries[PostID(id)], now: Date(), imagePipeline: imagePipeline
            )
        }
        let emptyRegistration = UICollectionView.CellRegistration<WalletEmptyStakesCell, Item> { _, _, _ in }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .summary:
                collectionView.dequeueConfiguredReusableCell(using: summaryRegistration, for: indexPath, item: item)
            case .stake:
                collectionView.dequeueConfiguredReusableCell(using: stakeRegistration, for: indexPath, item: item)
            case .noActiveStakes:
                collectionView.dequeueConfiguredReusableCell(using: emptyRegistration, for: indexPath, item: item)
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<WalletSectionHeader>(
            elementKind: WalletSectionHeader.kind
        ) { [weak self] header, _, indexPath in
            guard let self, let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
            configure(header, for: section)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func configure(_ header: WalletSectionHeader, for section: Section) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        switch section {
        case .summary:
            break
        case .active:
            let staked = stakes.filter { !$0.isSettled }.reduce(0) { $0 + $1.amount }
            let detail = NSMutableAttributedString()
            if staked > 0 {
                detail.append(walletAmount("\(staked)", glyph: PointsSymbol.glyphImage(), font: font, color: .secondaryLabel))
                detail.append(NSAttributedString(string: " at stake", attributes: [.font: font]))
            }
            header.configure(title: "Active stakes", detail: detail)
        case .settled:
            let earned = stakes.reduce(0) { $0 + $1.gems }
            let detail = NSMutableAttributedString(attributedString: walletAmount(
                "+\(earned)", glyph: GemSymbol.glyphImage(), font: font, color: GemSymbol.tint
            ))
            detail.append(NSAttributedString(string: " earned", attributes: [.font: font]))
            header.configure(title: "Settled", detail: detail)
        }
    }

    /// The compact bar, the bottom blur and the Claim button, above the list.
    private func buildChrome() {
        bottomBlur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBlur)
        compactBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(compactBar)

        claimButton.configuration?.cornerStyle = .capsule
        claimButton.addAction(UIAction { [weak self] _ in self?.claimTapped() }, for: .primaryActionTriggered)
        PressFeedback.attach(to: claimButton, sound: nil)
        claimButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(claimButton)

        let margin = WalletSheetMetrics.sideMargin
        let leading = claimButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin)
        let trailing = claimButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin)
        let bottom = claimButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin)
        NSLayoutConstraint.activate([
            compactBar.topAnchor.constraint(equalTo: view.topAnchor),
            compactBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            compactBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            compactBar.heightAnchor.constraint(equalToConstant: Self.compactBarHeight),
            claimButton.heightAnchor.constraint(equalToConstant: WalletSheetMetrics.claimHeight),
            leading, trailing, bottom,
            // From a little above the button to the foot: the ramp is clear
            // at its top, so rows dissolve on their way under.
            bottomBlur.topAnchor.constraint(equalTo: claimButton.topAnchor, constant: -Spacing.xl),
            bottomBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        buttonLeading = leading
        buttonTrailing = trailing
        buttonBottom = bottom
        applyListBottomInset()
    }

    /// The list's last row can always scroll clear of the button.
    private func applyListBottomInset() {
        collectionView.contentInset.bottom = WalletSheetMetrics.claimHeight + buttonMargin + Spacing.lg
        collectionView.verticalScrollIndicatorInsets.bottom = collectionView.contentInset.bottom
    }

    /// Gives the sheet THE DEVICE'S own corner radius and nests the button in
    /// it: margin = device radius − capsule radius on all three edges, so the
    /// pill stays concentric with the sheet's corners on every screen.
    private func applyDeviceCornerRadius() {
        guard view.window != nil, let sheet = sheetPresentationController else { return }
        let device = ScreenGeometry.cornerRadius(behind: view)
        guard device > 0, abs(device - appliedSheetRadius) > 0.5 else { return }
        appliedSheetRadius = device
        buttonMargin = max(WalletSheetMetrics.sideMargin, device - WalletSheetMetrics.claimHeight / 2)
        sheet.preferredCornerRadius = device
        buttonLeading?.constant = buttonMargin
        buttonTrailing?.constant = -buttonMargin
        buttonBottom?.constant = -buttonMargin
        applyListBottomInset()
    }

    /// The SMALL detent: the summary and the first `smallDetentRows` rows of
    /// the list, then the button. Measured from the laid-out list rather than
    /// typed, so Dynamic Type, a longer streak line or a list of one cannot
    /// cut a row in half. Skipped once the sheet has forgotten the detent.
    private func updateSmallDetent() {
        guard let sheet = sheetPresentationController,
              sheet.detents.contains(where: { $0.identifier == Self.smallDetent }) else { return }
        var bottom: CGFloat?
        let rows = dataSource.snapshot().itemIdentifiers.filter { $0 != .summary }.prefix(Self.smallDetentRows)
        for item in rows {
            guard let path = dataSource.indexPath(for: item),
                  let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { continue }
            bottom = max(bottom ?? 0, frame.maxY)
        }
        if bottom == nil, let summary = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
            bottom = summary.frame.maxY
        }
        guard let bottom else { return }
        // ⚠️ A custom detent's height EXCLUDES the bottom safe area — the
        // sheet adds it back. Read from the PRESENTER's window too: this is
        // measured in `viewDidLoad`, before the sheet has a window of its own.
        let window = view.window ?? presentingViewController?.view.window
        let bottomInset = window?.safeAreaInsets.bottom ?? 0
        // `Spacing.xl` above the button: the bottom blur starts there, so the
        // last row shown ends where the dissolve begins and reads whole.
        let height = (Self.topInset + bottom + Spacing.xl + WalletSheetMetrics.claimHeight
            + buttonMargin - bottomInset).rounded()
        guard abs(height - smallDetentHeight) > 0.5 else { return }
        smallDetentHeight = height
        sheet.invalidateDetents()
    }

    /// Once LARGE, the small detent is dropped: a drag down from the top then
    /// closes the sheet in one motion instead of parking it halfway.
    private func forgetSmallDetentOnceLarge() {
        guard let sheet = sheetPresentationController, sheet.selectedDetentIdentifier == .large,
              sheet.detents.count > 1 else { return }
        sheet.detents = [.large()]
    }

    /// The summary collapses into the compact bar as it scrolls under the
    /// grabber: the bar fades in while the summary's last `Spacing.lg` slides
    /// beneath it, and is opaque once the card has fully passed under.
    private func updateCompactBar() {
        guard let summary = summaryCell else { return }
        // The summary's bottom edge, in the sheet's own coordinates.
        let visibleBottom = summary.frame.maxY - collectionView.contentOffset.y
        let progress = min(1, max(0, (Self.compactBarHeight + Spacing.lg - visibleBottom) / Spacing.lg))
        compactBar.progress = progress
    }

    // MARK: - State

    private func refresh() {
        snapshot = wallet.snapshot()
        stakes = wallet.stakes()
        stakesByID = Dictionary(uniqueKeysWithValues: stakes.map { ($0.targetID, $0) })

        summaryCell?.summary.configure(with: snapshot)
        compactBar.configure(points: snapshot.balance, gems: snapshot.gems)
        applyClaimButtonState()

        var list = NSDiffableDataSourceSnapshot<Section, Item>()
        list.appendSections([.summary, .active])
        list.appendItems([.summary], toSection: .summary)
        let active = stakes.filter { !$0.isSettled }
        list.appendItems(active.isEmpty ? [.noActiveStakes] : active.map { .stake($0.targetID) }, toSection: .active)
        let settled = stakes.filter(\.isSettled)
        if !settled.isEmpty {
            list.appendSections([.settled])
            list.appendItems(settled.map { .stake($0.targetID) }, toSection: .settled)
        }
        // Rows whose stake moved (settled, grew) are reconfigured in place.
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        list.reconfigureItems(list.itemIdentifiers.filter {
            if case .stake = $0 { return previous.contains($0) } else { return false }
        })
        dataSource.apply(list, animatingDifferences: collectionView.window != nil)
        // The headers' totals follow the stakes.
        for kind in [Section.active, .settled] {
            guard let index = list.indexOfSection(kind),
                  let header = collectionView.supplementaryView(
                      forElementKind: WalletSectionHeader.kind, at: IndexPath(item: 0, section: index)
                  ) as? WalletSectionHeader else { continue }
            configure(header, for: kind)
        }
        loadMissingPosts()
    }

    /// Asks for the posts behind stakes it has not seen yet, and redraws those
    /// rows when they arrive.
    private func loadMissingPosts() {
        guard let lookUpPosts else { return }
        let missing = stakes.map { PostID($0.targetID) }
            .filter { entries[$0] == nil && !requestedPosts.contains($0) }
        guard !missing.isEmpty else { return }
        requestedPosts.formUnion(missing)
        Task { [weak self] in
            let found = await lookUpPosts(missing)
            guard let self, !found.isEmpty else { return }
            entries.merge(found) { _, new in new }
            var list = dataSource.snapshot()
            let rows = found.keys.map { Item.stake($0.rawValue) }.filter { list.indexOfItem($0) != nil }
            list.reconfigureItems(rows)
            await dataSource.apply(list, animatingDifferences: false)
        }
    }

    private func applyClaimButtonState() {
        claimButton.isEnabled = snapshot.claimAvailable
        var title: AttributedString
        if snapshot.claimAvailable {
            title = AttributedString("Claim \(snapshot.claimAmount) points")
        } else if snapshot.claimedToday >= snapshot.dailyClaimCap, let next = snapshot.nextClaimAt {
            title = AttributedString("Daily cap reached — resets in \(Self.countdownString(to: next))")
        } else if let next = snapshot.nextClaimAt {
            title = AttributedString("Next claim in \(Self.countdownString(to: next))")
        } else {
            title = AttributedString("Claim")
        }
        title.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        claimButton.configuration?.attributedTitle = title
    }

    private func claimTapped() {
        switch wallet.claim() {
        case .claimed:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Explicit refresh, not the observer's: its queue hop is UIKit's
            // business, and the pop below must scale the NEW number.
            refresh()
            summaryCell?.summary.pointsTile.pop()
        case .tooEarly, .dailyCapReached:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            refresh()
        }
    }

    // MARK: - Clock

    /// Once a second: the claim countdown, and the active stakes' "settles
    /// in" lines. A stake that has just settled refreshes the whole sheet — it
    /// moves section, and the gems balance moves with it.
    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func tick() {
        let now = Date()
        if stakes.contains(where: { !$0.isSettled && $0.settlesAt <= now }) {
            refresh()
            return
        }
        snapshot = wallet.snapshot()
        applyClaimButtonState()
        for cell in collectionView.visibleCells {
            guard let cell = cell as? WalletStakeCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  case .stake(let id) = dataSource.itemIdentifier(for: indexPath),
                  let stake = stakesByID[id], !stake.isSettled else { continue }
            cell.applyStatus(stake: stake, now: now)
        }
    }

    /// "42:07" under an hour, "3h 12m" above it.
    private static func countdownString(to date: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        if remaining >= 3600 {
            return "\(remaining / 3600)h \((remaining % 3600) / 60)m"
        }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

extension WalletClaimViewController: UISheetPresentationControllerDelegate {
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheetPresentationController: UISheetPresentationController
    ) {
        forgetSmallDetentOnceLarge()
    }
}

extension WalletClaimViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCompactBar()
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }
}

/// Holds notification tokens and unregisters them on its own deallocation
/// (when the owning sheet is released). `@unchecked Sendable` so its deinit
/// may run off the main actor; `removeObserver` is itself thread-safe, and
/// the tokens are only written on the main actor at setup time. `nonisolated`,
/// because the App target's default-MainActor isolation would otherwise pin
/// `tokens` to the main actor and put it out of deinit's reach.
private nonisolated final class WalletObserverTokenBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
