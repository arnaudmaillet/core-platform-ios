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
///   • the SUMMARY — Points and Gems side by side, then one compact card:
///     the streak on the left, today's earnings on the right
///     (`WalletSummaryView`);
///   • ACTIVE STAKES — each post, the points on it, and how long until it
///     settles;
///   • SETTLED — each post and what it earned in gems, or "No reward";
///   • the CLAIM button, pinned to the sheet's bottom whatever is scrolled.
///
/// # Two detents
/// The sheet opens LARGE, with the stakes in view. It keeps a lower INFO
/// detent that shows exactly the summary and the button — the glance-and-
/// claim surface the sheet used to be — with the list below the fold. Once
/// the summary has scrolled away it collapses into a compact bar under the
/// grabber (`WalletCompactBar`), so the list is never read without the
/// balances.
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
    /// Solid ground under the button, from `Spacing.lg` above it to the
    /// sheet's bottom edge. The list ENDS at its top rather than scrolling
    /// under it: ⚠️ the glass button samples what lies beneath it straight
    /// through an opaque sibling, and drew the list's rows around itself at
    /// the INFO detent (measured with a red band — the rows sat on top).
    private let claimBand = UIView()

    private var snapshot: WalletSnapshot
    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: FeedEntry] = [:]
    private var requestedPosts: Set<PostID> = []

    private var countdownTimer: Timer?
    private let walletObservers = WalletObserverTokenBag()

    /// The INFO detent's height, measured from the laid-out summary — a
    /// stored number, because a detent resolver must read nothing that could
    /// load a view.
    private var infoDetentHeight: CGFloat = 360
    private static let infoDetent = UISheetPresentationController.Detent.Identifier("wallet.info")

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
                .custom(identifier: Self.infoDetent) { [weak self] _ in self?.infoDetentHeight ?? 360 },
                .large(),
            ]
            // ⚠️ OPENS AT THE TOP, and keeps the lower detent to rest on.
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.preferredCornerRadius = WalletSheetMetrics.claimHeight / 2 + WalletSheetMetrics.sideMargin
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
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

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // `-wallet-demo-claim`: fires the Claim button once the sheet is up —
        // the real claim path minus the finger. Pair with `-open-wallet
        // -wallet-claim-ready`.
        if arguments.contains("-wallet-demo-claim") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.claimTapped()
            }
        }
        // `-wallet-sheet-info`: rests the sheet on its INFO detent once it has
        // landed, so the lower resting state can be screenshotted.
        if arguments.contains("-wallet-sheet-info") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let sheet = self?.sheetPresentationController else { return }
                sheet.animateChanges { sheet.selectedDetentIdentifier = Self.infoDetent }
            }
        }
        // `-wallet-sheet-scroll <pt>`: scrolls the list once the sheet has
        // landed, so the collapsed header can be screenshotted.
        if let index = arguments.firstIndex(of: "-wallet-sheet-scroll"), index + 1 < arguments.count,
           let offset = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
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
        updateInfoDetent()
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
                detail.append(walletGlyph(PointsSymbol.glyphImage(), font: font))
                detail.append(NSAttributedString(string: " \(staked) at stake", attributes: [.font: font]))
            }
            header.configure(title: "Active stakes", detail: detail)
        case .settled:
            let earned = stakes.reduce(0) { $0 + $1.gems }
            let detail = NSMutableAttributedString(string: "+\(earned) ", attributes: [
                .font: font, .foregroundColor: GemSymbol.tint,
            ])
            detail.append(walletGlyph(GemSymbol.glyphImage(), font: font))
            detail.append(NSAttributedString(string: " earned", attributes: [.font: font]))
            header.configure(title: "Settled", detail: detail)
        }
    }

    /// The compact bar and the Claim button, above the list.
    private func buildChrome() {
        compactBar.alpha = 0
        compactBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(compactBar)

        claimBand.backgroundColor = .systemBackground
        claimBand.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(claimBand)

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
            claimBand.topAnchor.constraint(equalTo: claimButton.topAnchor, constant: -Spacing.lg),
            claimBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            claimBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            claimBand.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: claimBand.topAnchor),
        ])
        buttonLeading = leading
        buttonTrailing = trailing
        buttonBottom = bottom
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
    }

    /// The INFO detent: exactly the summary and the button — the band's top
    /// lands on the summary's bottom, so nothing of the list shows between
    /// them. Measured from the laid-out summary rather than typed, so Dynamic
    /// Type and a longer streak line cannot put the button over the card.
    private func updateInfoDetent() {
        guard let summary = summaryCell, summary.window != nil else { return }
        let summaryBottom = Self.topInset + summary.frame.maxY
        // ⚠️ A custom detent's height EXCLUDES the bottom safe area — the
        // sheet adds it back — so the window's inset comes off here, or the
        // sheet rests 34pt tall with the list's first header showing.
        let bottomInset = view.window?.safeAreaInsets.bottom ?? 0
        let height = (summaryBottom + Spacing.lg + WalletSheetMetrics.claimHeight + buttonMargin - bottomInset).rounded()
        guard abs(height - infoDetentHeight) > 0.5 else { return }
        infoDetentHeight = height
        sheetPresentationController?.invalidateDetents()
    }

    /// The summary collapses into the compact bar as it scrolls under the
    /// grabber: the bar fades in while the summary's last `Spacing.lg` slides
    /// beneath it, and is opaque once the card has fully passed under.
    private func updateCompactBar() {
        guard let summary = summaryCell else { return }
        // The summary's bottom edge, in the sheet's own coordinates.
        let visibleBottom = summary.frame.maxY - collectionView.contentOffset.y
        let progress = min(1, max(0, (Self.compactBarHeight + Spacing.lg - visibleBottom) / Spacing.lg))
        compactBar.alpha = progress
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
