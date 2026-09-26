import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
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
///     with the list dissolving under it.
///
/// # Small, then large — a native sheet
/// The sheet opens SMALL: the summary and the first two stakes at most — the
/// glance-and-claim surface. Scrolling the list up grows it to LARGE (the
/// sheet's own `prefersScrollingExpandsWhenScrolledToEdge`), and a drag down
/// from large comes back to SMALL before it closes (26 September 2026 — the
/// earlier "forget small once large" rule was reversed the same day). Its
/// ground is the SYSTEM's: glass while small, opaque once large, exactly as a
/// native sheet (the profile's QR sheet) behaves — so the view is clear and
/// paints nothing of its own. Once the summary has scrolled away it collapses
/// into a compact bar under the grabber (`WalletCompactBar`), so the list is
/// never read without the balances.
///
/// # The edges
/// The list passes under the compact bar and the Claim button through the
/// system's own SOFT scroll-edge effect — a blur that ramps in strength rather
/// than a material faded by a mask. The hand-built material blurs this
/// replaced read as two frosted slabs: "beaucoup trop opaque, on n'aperçoit
/// pas la collection view".
///
/// Everything derives from one `WalletSnapshot` and one `stakes()` reading per
/// refresh; the only per-second work is the claim countdown and the active
/// stakes' "settles in" lines.
final class WalletClaimViewController: UIViewController {
    /// Resolves stake targets to their posts — the Feed feature's, handed in
    /// by the composition root (`AppContainer.makeWalletSheet`).
    typealias PostLookup = @MainActor ([PostID]) async -> [PostID: GalleryPost]
    /// Opens the feed on `postIDs` from `presenter`, flying from `origin` —
    /// the Feed feature's `presentSnapFeedHero`, the For You and Profile
    /// cards' own way in.
    typealias OpenFeedHero = @MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void

    private let wallet: WalletStore
    private let lookUpPosts: PostLookup?
    private let imagePipeline: ImagePipeline?
    private let openFeedHero: OpenFeedHero?

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
    /// The Claim button's container, registered with the list's BOTTOM scroll
    /// edge so the system's soft edge effect grows to sit behind it.
    private let claimBar = UIView()

    private var snapshot: WalletSnapshot
    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: GalleryPost] = [:]
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

    init(
        wallet: WalletStore,
        lookUpPosts: PostLookup? = nil,
        imagePipeline: ImagePipeline? = nil,
        openFeedHero: OpenFeedHero? = nil
    ) {
        self.openFeedHero = openFeedHero
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
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The grouped page — For You's and Profile's — so the stake cards are
        // white ON it rather than grey on white.
        // ⚠️ CLEAR: the sheet's own ground is the surface — glass while
        // small, opaque once large. Any colour here sits over the glass and
        // defeats it (the QR sheet's note says the same).
        view.backgroundColor = .clear
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
            }
        }
        // `-wallet-open-stake <n>`: opens the n-th stake row's post (0-based,
        // list order) once its post has loaded — the row's own tap path.
        if let index = arguments.firstIndex(of: "-wallet-open-stake"), index + 1 < arguments.count,
           let row = Int(arguments[index + 1]) {
            let stakeID: @MainActor () -> String? = { [weak self] in
                guard let self else { return nil }
                let ids = dataSource.snapshot().itemIdentifiers.compactMap { item -> String? in
                    if case .stake(let id) = item { id } else { nil }
                }
                return ids.indices.contains(row) ? ids[row] : nil
            }
            QAWait.until("-wallet-open-stake \(row)", { [weak self] in
                guard let self else { return true }
                guard landed(), let id = stakeID() else { return false }
                return entries[PostID(id)] != nil && stakeCell(for: id) != nil
            }) { [weak self] in
                guard let id = stakeID() else { return }
                self?.openFeed(fromStake: id)
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
                stake: stake, post: entries[PostID(id)], now: Date(), imagePipeline: imagePipeline
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

    /// The compact bar and the Claim button, above the list — each registered
    /// with the list's scroll edge on its side, so the system draws the soft
    /// edge effect behind them (`UIScrollEdgeElementContainerInteraction`).
    private func buildChrome() {
        collectionView.topEdgeEffect.style = .soft
        // Hidden at rest; `updateCompactBar` shows it with the bar.
        collectionView.topEdgeEffect.isHidden = true
        collectionView.bottomEdgeEffect.style = .soft

        compactBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(compactBar)
        let topEdge = UIScrollEdgeElementContainerInteraction()
        topEdge.scrollView = collectionView
        topEdge.edge = .top
        compactBar.addInteraction(topEdge)

        claimBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(claimBar)
        let bottomEdge = UIScrollEdgeElementContainerInteraction()
        bottomEdge.scrollView = collectionView
        bottomEdge.edge = .bottom
        claimBar.addInteraction(bottomEdge)

        claimButton.configuration?.cornerStyle = .capsule
        claimButton.addAction(UIAction { [weak self] _ in self?.claimTapped() }, for: .primaryActionTriggered)
        PressFeedback.attach(to: claimButton, sound: nil)
        claimButton.translatesAutoresizingMaskIntoConstraints = false
        claimBar.addSubview(claimButton)

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
            // The container spans from just above the button to the foot —
            // the extent the edge effect covers.
            claimBar.topAnchor.constraint(equalTo: claimButton.topAnchor, constant: -Spacing.sm),
            claimBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            claimBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            claimBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    /// The summary collapses into the compact bar as it scrolls under the
    /// grabber: the bar fades in while the summary's last `Spacing.lg` slides
    /// beneath it, and is opaque once the card has fully passed under.
    private func updateCompactBar() {
        guard let summary = summaryCell else { return }
        // The summary's bottom edge, in the sheet's own coordinates.
        let visibleBottom = summary.frame.maxY - collectionView.contentOffset.y
        let progress = min(1, max(0, (Self.compactBarHeight + Spacing.lg - visibleBottom) / Spacing.lg))
        compactBar.progress = progress
        // ⚠️ THE TOP EDGE EFFECT ONLY WHILE THE BAR IS THERE. The compact bar
        // is registered with the list's top edge and spans the first 44pt of
        // the sheet — which, at rest, is where the summary's "Points" and
        // "Gems" labels sit. The system shows the effect once the list has
        // scrolled at all and keeps it on the way back up, so after one
        // round trip the labels rested under a blur (device screenshots,
        // 26 September 2026). With nothing collapsed there is nothing for the
        // blur to separate.
        let hidesTopEdge = progress == 0
        if collectionView.topEdgeEffect.isHidden != hidesTopEdge {
            collectionView.topEdgeEffect.isHidden = hidesTopEdge
        }
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

    // MARK: - Opening a stake

    /// Opens the feed on the staked posts, from the tapped one on, flying out
    /// of its row the way a For You or Profile card opens — the thumbnail for
    /// a media post, the card itself (the text reveal) for a text post.
    ///
    /// ⚠️ **OVER THE SHEET, NOT INSIDE IT.** The feed flies with a navigation
    /// push, and a sheet's own stack would keep the feed in the sheet's shape.
    /// So a clear, full-screen stack is presented over the sheet without
    /// animation (`StakeFeedHost`), the feed is pushed onto IT, and the flight
    /// measures the row through the clear host — the sheet stays visible
    /// underneath for the whole trip. The host dismisses itself, unanimated,
    /// once the feed has flown home.
    ///
    /// The window is the list's own order from the tapped row down, so the
    /// feed pages through the stakes exactly as the sheet lists them; and a
    /// dismissal lands on the row that opened it, whatever the viewer paged
    /// to — the product rule of every ranked list in the app — crossfading
    /// when the page it closes is another post's.
    private func openFeed(fromStake id: String) {
        guard let openFeedHero, presentedViewController == nil,
              let post = entries[PostID(id)] else { return }
        let order = dataSource.snapshot().itemIdentifiers.compactMap { item -> String? in
            if case .stake(let stake) = item { stake } else { nil }
        }
        guard let start = order.firstIndex(of: id) else { return }
        let stream = Array(order[start...].compactMap { entries[PostID($0)] }.prefix(Self.feedWindow))
        let origin = heroOrigin(for: post, stakeID: id, stream: stream)

        let host = StakeFeedHost()
        let stack = UINavigationController(rootViewController: host)
        stack.setNavigationBarHidden(true, animated: false)
        stack.modalPresentationStyle = .overFullScreen
        stack.view.backgroundColor = .clear
        present(stack, animated: false) { [weak host] in
            guard let host else { return }
            openFeedHero(stream.map(\.id), host, origin)
        }
    }

    /// How many stakes the feed is opened on, from the tapped one down.
    private static let feedWindow = 20

    private func stakeCell(for id: String) -> WalletStakeCell? {
        guard let path = dataSource.indexPath(for: .stake(id)) else { return nil }
        return collectionView.cellForItem(at: path) as? WalletStakeCell
    }

    /// The row's thumbnail (media) or card (text), in `space` — nil once it
    /// has scrolled out of the list's visible part.
    private func stakeFrame(for id: String, card: Bool, in space: UICoordinateSpace) -> CGRect? {
        guard let cell = stakeCell(for: id) else { return nil }
        let inList = cell.convert(cell.bounds, to: collectionView)
        guard collectionView.bounds.intersects(inList) else { return nil }
        return card ? cell.convert(cell.bounds, to: space) : cell.heroFrame(in: space)
    }

    private func heroOrigin(for post: GalleryPost, stakeID id: String, stream: [GalleryPost]) -> SnapFeedHeroOrigin {
        let cell = stakeCell(for: id)
        let cover = cell?.heroCover
        let flies = post.kind != .text
        // ⚠️ THE ROW IS NOT THE PAGE, so a text post's window needs a
        // stand-in at both ends — the map marker's case, not the For You
        // card's. A card's caption IS the page's caption, so its window can
        // show the real page from frame 0; this row is an author, a snippet
        // and a stake amount, and without a stand-in the window landed as a
        // blank white card that sat there until the row popped back in
        // (filmed: a third of a second). A picture of the row, taken now
        // while it is still drawn, is what the window crossfades to and from.
        let rowImage = cell?.renderedImage()
        let standIn: () -> UIView? = {
            guard let rowImage else { return nil }
            let view = UIImageView(image: rowImage)
            // At its own size, pinned top-left: the window is the row's rect
            // only at the two ends, and a stretched row between them read as
            // a smear (filmed on the opening).
            view.contentMode = .topLeft
            view.clipsToBounds = true
            return view
        }
        return SnapFeedHeroOrigin(
            post: post,
            stream: stream,
            hasHero: flies,
            cover: cover,
            // `.listMedia`: no counter chips riding the card (a tile's
            // furniture flashed over the 48pt thumbnail on landing), and the
            // same 12pt corner the thumbnail wears.
            style: .listMedia,
            frame: { [weak self] space in self?.stakeFrame(for: id, card: false, in: space) },
            isOnScreen: { [weak self] in
                guard let self else { return false }
                return stakeFrame(for: id, card: false, in: view) != nil
            },
            setConcealed: { [weak self] concealed in
                self?.stakeCell(for: id)?.setHeroConcealed(concealed, wholeCard: false)
            },
            // No depth cue for the FLIGHT: the list it would recede is the
            // very surface the landing is measured on (see the PR).
            textReveal: flies ? nil : TextRevealOrigin(
                rowFrame: { [weak self] space in self?.stakeFrame(for: id, card: true, in: space) },
                captionEnd: nil,
                depthView: { [weak self] in self?.collectionView },
                makeDismissStandIn: { _ in standIn() },
                makePresentStandIn: standIn,
                alignsPageToSource: false,
                pageFit: .covering,
                cornerRadius: WalletSheetMetrics.rowCorner,
                fill: Surface.card,
                setConcealed: { [weak self] concealed in
                    self?.stakeCell(for: id)?.setHeroConcealed(concealed, wholeCard: true)
                }
            )
        )
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

    /// A stake row opens its post; nothing else on the sheet is pressable.
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard case .stake(let id) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return entries[PostID(id)] != nil && openFeedHero != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard case .stake(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        openFeed(fromStake: id)
    }
}

/// The clear root of the stack a stake's feed is pushed onto, presented over
/// the wallet sheet (`WalletClaimViewController.openFeed`). It draws nothing
/// — the sheet stays visible through it for the flight both ways — and takes
/// the stack away, unanimated, once the feed has been popped back to it.
private final class StakeFeedHost: UIViewController {
    private var hasShownFeed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Covered by the feed's push.
        if navigationController?.topViewController !== self { hasShownFeed = true }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Back on top after the feed: the trip is over.
        guard hasShownFeed else { return }
        navigationController?.presentingViewController?.dismiss(animated: false)
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
