import AuthInterface
import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import FeedInterface
import Maps
import MapsInterface
import MediaCore
import PostGrid
import UIKit

/// The Wallet (#1494, the owner 2026-10-20): ONE sheet with two heights —
/// the Claim sheet and the hub it used to push (#1476), folded into one list,
/// laid out after Telegram's Wallet.
///
/// ```
///   [?]              Wallet              [✕]
///
///                    (♥)
///                    282
///                   Likes
///
///   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
///   🔥 3-day streak · Kept for today   25 / 200 today
///   M  T  W  T  F  S  S          ( ×1.3 tomorrow )
///   ┌──────────────────┐ ┌────────┐ ┌────────┐
///   │      127 ◆       │ │   ✓    │ │   ≡    │
///   │       Shop       │ │Settled │ │Activity│
///   └──────────────────┘ └────────┘ └────────┘
///   ┌──────────────────────────────────────────┐
///   │            Claim 25 likes                │   ← the small height ends here
///   └──────────────────────────────────────────┘
///   Active stakes ›                  46 ♥ at stake
///   ┌──────────────────────────────────────────┐
///   │ ▢ Standup moved to nine…           1 ♥   │
///   │ ──────────────────────────────────────── │
///   │ ▢ Refactor landed and…             8 ♥   │
///   └──────────────────────────────────────────┘
/// ```
///
/// # Two heights, one top
///   • SMALL (it opens here): the daily glance, measured to end under the
///     Claim — a stored number, see `updateDetent`.
///   • LARGE (pulled up, or scrolled: a scroll in the small sheet grows it
///     before anything scrolls): the same list, the same top at the same
///     place — growing only uncovers the active stakes. From there the
///     sheet keeps large alone, so a drag down closes it (`expand`).
///   Pushing Stakes, Activity or How it works keeps the sheet's height.
///
/// # The economy it shows (`dev/economy/`, charter V5.3)
///   • **Likes** (currency A, the heart) — curation capacity: claimed, spent
///     by STAKING on posts;
///   • **Gems** (currency B, the diamond) — earned-only: what a stake pays
///     once it SETTLES, if it turned out to carry information.
/// What is past — the settled stakes, the history — is behind a door; what
/// is current — the active stakes — is on the page.
///
/// # Surfaces
/// The app's grouped page and cards (`Surface`), at both heights: the page
/// is painted, so the small sheet is opaque too — a card on the glass read
/// darker than its ground (the owner, 2026-10-20). The Claim is the head's,
/// the whole width under the doors — no toolbar: a toolbar's custom view
/// reached the bar ~0.4 s after the sheet (filmed, 2026-10-20), and a native
/// item stays at its words' width.
final class WalletSheetViewController: UIViewController {
    /// Resolves stake targets to their posts — the Feed feature's, handed in
    /// by the composition root (`AppContainer.makeWalletSheet`).
    typealias PostLookup = @MainActor ([PostID]) async -> [PostID: GalleryPost]
    /// Opens the feed on `postIDs` from `presenter`, flying from `origin` —
    /// the Feed feature's `presentSnapFeedHero`, the For You and Profile
    /// cards' own way in.
    typealias OpenFeedHero = @MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void

    /// A member's wallet: a guest never gets this sheet (#1146,
    /// `AppContainer.makeWalletSheet`).
    private let wallet: WalletStore
    private let lookUpPosts: PostLookup?
    private let imagePipeline: ImagePipeline?
    private let openFeedHero: OpenFeedHero?
    /// "Find a post to stake": the feed, the sheet down (`AppRoute.feed`).
    private let findPosts: (() -> Void)?
    /// The account's countries — what the Shop sells. Nil: no Shop door.
    private let countries: (any CountryAccess)?
    /// The Shop's Boosts — the ×100 cartridge pack. Nil sells none.
    private let stakePacks: (any StakePackSelling)?
    private let profileItems: (any ProfileItemSelling)?
    /// The Shop's Themes (#1379). Nil sells none.
    private let themes: (any ThemeSelling)?
    /// The Shop's posters and preview loops (#1075).
    private let shopMedia: ShopMedia?

    private nonisolated enum Section: Hashable { case top, active }
    private nonisolated enum Item: Hashable {
        /// The head: balance, gauge, streak, week, the three doors.
        case header
        case stake(String)
        case noActiveStakes
        case postsFailed
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let claimer: WalletClaimer
    /// The likes gauge, the bar's subtitle.
    private let titleGauge = WalletTitleGauge()

    private var snapshot: WalletSnapshot
    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: GalleryPost] = [:]
    /// Where each stake's post lookup stands — what its row draws (bones,
    /// the post, or "couldn't load") and whether the failed row shows (#834).
    private var postLoads = WalletStakePostLoads()

    private var countdownTimer: Timer?
    private let walletObservers = WalletObserverTokenBag()

    /// Room under the bar before the balance: the balance's air (#1494).
    private static let topInset: CGFloat = Spacing.xl

    /// The head's height with the gap under it — where the Active stakes
    /// heading starts in the list's content. Measured with the detent.
    private var headerHeight: CGFloat = 0

    /// The small detent's height, measured from the laid-out list — a stored
    /// number, because a detent resolver must read nothing that could load a
    /// view.
    private var detentHeight: CGFloat = 560
    static let smallDetent = UISheetPresentationController.Detent.Identifier("wallet.small")

    /// Stable identifiers: a reused bar item identifier is how iOS 26 matches
    /// an item across a reinstall.
    static let closeItemIdentifier = "wallet.close"
    static let helpItemIdentifier = "wallet.help"

    /// The history's first pages on the device (#1776).
    private let historyCache: WalletHistoryLocalCache?

    init(
        wallet: WalletStore,
        lookUpPosts: PostLookup? = nil,
        imagePipeline: ImagePipeline? = nil,
        openFeedHero: OpenFeedHero? = nil,
        findPosts: (() -> Void)? = nil,
        countries: (any CountryAccess)? = nil,
        stakePacks: (any StakePackSelling)? = nil,
        profileItems: (any ProfileItemSelling)? = nil,
        themes: (any ThemeSelling)? = nil,
        shopMedia: ShopMedia? = nil,
        historyCache: WalletHistoryLocalCache? = nil
    ) {
        self.historyCache = historyCache
        self.wallet = wallet
        self.claimer = WalletClaimer(wallet: wallet)
        self.lookUpPosts = lookUpPosts
        self.imagePipeline = imagePipeline
        self.openFeedHero = openFeedHero
        self.findPosts = findPosts
        self.countries = countries
        self.stakePacks = stakePacks
        self.profileItems = profileItems
        self.themes = themes
        self.shopMedia = shopMedia
        self.snapshot = wallet.snapshot()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet as it is presented: this screen as the root of a navigation
    /// controller that shows its bar, as a page sheet at its
    /// small height.
    ///
    /// ⚠️ The sheet's configuration lives on the NAVIGATION controller's
    /// presentation — the one presented.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        // Settled and Activity wear their title large (#1494); Rewards keeps
        // its inline title and gauge.
        navigation.navigationBar.prefersLargeTitles = true
        if let sheet = navigation.sheetPresentationController {
            let small = UISheetPresentationController.Detent.custom(identifier: Self.smallDetent) { [weak self] context in
                min(self?.detentHeight ?? 560, context.maximumDetentValue)
            }
            let large = largeDetent
            // ⚠️ OPAQUE AT BOTH HEIGHTS (#1494, the owner 2026-10-20): the
            // small height's default glass re-inked the grouped tones — the
            // page drew white and the cards grey, the wrong way round. The
            // page's own colour is the sheet's ground instead.
            //
            // ⚠️ ON THE PRESENTATION TOO, not only the detents: during the
            // rise the sheet was still glass, and its labels drew vibrant —
            // "Likes" and the authors' names took the map's colour behind
            // until it landed (filmed on the device, 2026-10-21).
            if #available(iOS 26.1, *) {
                small.backgroundEffect = UIColorEffect(color: Surface.page)
                sheet.backgroundEffect = UIColorEffect(color: Surface.page)
            }
            // Collapsed first (#1494, the owner 2026-10-21): the daily glance.
            // Pulled up, it expands — and from there a drag down stops at the
            // collapsed height before closing (#1732, the owner 2026-10-25:
            // the halfway detent is back).
            sheet.detents = [small, large]
            sheet.selectedDetentIdentifier = Self.smallDetent
            #if DEBUG
            // `-wallet-sheet-large`: opens expanded, for screenshots and tests.
            if ProcessInfo.processInfo.arguments.contains("-wallet-sheet-large") {
                sheet.detents = [large]
                sheet.selectedDetentIdentifier = .large
            }
            #endif
            // A scroll in the small sheet grows it before anything scrolls:
            // the balance never scrolls away inside a half sheet.
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersGrabberVisible = true
            sheet.delegate = self
            // ⚠️ NO `preferredCornerRadius`: UIKit's own, concentric with
            // the device.
        }
        return navigation
    }

    /// The large detent, opaque as the small one (see `wrappedInSheet`).
    private lazy var largeDetent: UISheetPresentationController.Detent = {
        let large = UISheetPresentationController.Detent.large()
        if #available(iOS 26.1, *) { large.backgroundEffect = UIColorEffect(color: Surface.page) }
        return large
    }()

    /// Grows the sheet to its large height, KEEPING the collapsed detent
    /// (#1732, the owner): a drag down from expanded stops there first. It
    /// used to drop it (#1494), so a drag down closed the sheet outright.
    private func expand(_ sheet: UISheetPresentationController) {
        guard sheet.selectedDetentIdentifier != .large else { return }
        sheet.animateChanges {
            sheet.selectedDetentIdentifier = .large
        }
    }

    private var sheet: UISheetPresentationController? {
        navigationController?.sheetPresentationController
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The app's grouped page (#1494): cards lighter than their ground, at
        // both heights — the small sheet's glass is painted over on purpose.
        view.backgroundColor = Surface.page
        // The foot's blur, every screen's (#1002): over Rewards and what it
        // pushes, under the bar — the tab stacks' band, in this sheet's stack.
        if let navigationController { BottomEdgeBlurView.install(in: navigationController) }
        buildCollection()
        buildChrome()
        buildBar()
        // The server's wallet as of now (#1098): its change notice redraws.
        let wallet = wallet
        Task {
            await wallet.refreshFromServer()
            // Active and Settled are the server's (#903).
            await wallet.refreshStakesFromServer()
        }

        walletObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            NotificationCenter.default.addObserver(
                forName: WalletClaimer.didChangeNotification, object: claimer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            NotificationCenter.default.addObserver(
                forName: WalletClaimer.didClaimNotification, object: claimer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.headerCell?.header.popBalance() }
            },
        ]
        refresh()
        // Measured NOW, before the sheet asks its first detent: a guess here
        // would present at the guess and then jump to the answer.
        view.layoutIfNeeded()
        updateDetent()

        #if DEBUG
        installQAHooks()
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // How it works shows by itself once per account (#1480), the first
        // time the Wallet has landed.
        guard WalletHowItWorks.shouldShow(for: StorageScope.shared.owner) else { return }
        #if DEBUG
        // A QA run drives the sheet itself: `-wallet-how-it-works-seen`, or
        // any of the sheet's own hooks, keeps the page away.
        let hooks = [
            "-wallet-how-it-works-seen", "-wallet-open-stake", "-wallet-open-stakes", "-wallet-sheet-scroll",
            "-wallet-open-activity", "-wallet-demo-claim", "-wallet-open-shop",
        ]
        if ProcessInfo.processInfo.arguments.contains(where: hooks.contains) { return }
        #endif
        openHowItWorks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDetent()
    }

    // MARK: - Layout

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index) ?? .top
            let traits = environment.traitCollection
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)
            ))
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)),
                subitems: [item]
            )
            var layoutSection = NSCollectionLayoutSection(group: group)
            let margin = WalletSheetMetrics.sideMargin
            switch section {
            case .top:
                layoutSection.contentInsets = NSDirectionalEdgeInsets(
                    top: 0, leading: margin, bottom: SectionTitleView.gapAbove(traits: traits), trailing: margin
                )
            case .active:
                // The stakes are rows of ONE inset-grouped card (#1494), the
                // Settled and Activity screens' list: UIKit's ground, its
                // highlight under the finger. The rows draw their hairlines.
                let titleBar = SectionTitleView.barHeight(traits: traits)
                var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                configuration.showsSeparators = false
                configuration.backgroundColor = .clear
                let list = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                list.contentInsetsReference = .none
                list.contentInsets = NSDirectionalEdgeInsets(
                    top: SectionTitleView.gapBelow(traits: traits), leading: margin, bottom: 0, trailing: margin
                )
                list.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .absolute(titleBar)
                    ),
                    elementKind: WalletSectionHeader.kind, alignment: .top
                )]
                layoutSection = list
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
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let headerRegistration = UICollectionView.CellRegistration<WalletHeaderCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            configureHeader(cell.header)
            cell.header.onShop = { [weak self] in self?.openShop() }
            cell.header.onSettled = { [weak self] in self?.openStakes(.settled) }
            cell.header.onActivity = { [weak self] in self?.openActivity() }
            cell.header.onClaim = { [weak self] in self?.claim() }
        }
        let stakeRegistration = UICollectionView.CellRegistration<WalletGroupedStakeCell, Item> { [weak self] cell, indexPath, item in
            guard let self, case .stake(let id) = item else { return }
            cell.showsSeparator = indexPath.item > 0
            // Inside the apply: never animated (it would be swallowed). A post
            // landing on a visible row is cross-faded by `postsArrived`.
            configure(cell, stakeID: id, animated: false)
        }
        let emptyRegistration = UICollectionView.CellRegistration<WalletEmptyStakesCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.minimumHeight = emptyHeight
            drawnEmptyHeight = cell.minimumHeight
            if findPosts != nil { cell.onFindPosts = { [weak self] in self?.findPosts?() } }
        }
        let failedRegistration = UICollectionView.CellRegistration<WalletStakesFailedCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(retrying: postLoads.isRetrying, failedAfterRetry: postLoads.failedAfterRetry)
            cell.onRetry = { [weak self] in self?.retryFailedPosts() }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .header:
                collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: item)
            case .stake:
                collectionView.dequeueConfiguredReusableCell(using: stakeRegistration, for: indexPath, item: item)
            case .noActiveStakes:
                collectionView.dequeueConfiguredReusableCell(using: emptyRegistration, for: indexPath, item: item)
            case .postsFailed:
                collectionView.dequeueConfiguredReusableCell(using: failedRegistration, for: indexPath, item: item)
            }
        }
        let sectionHeaderRegistration = UICollectionView.SupplementaryRegistration<WalletSectionHeader>(
            elementKind: WalletSectionHeader.kind
        ) { [weak self] header, _, _ in
            self?.configureActiveHeader(header)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeaderRegistration, for: indexPath)
        }
    }

    /// The height an empty Active stakes card takes: what the sheet leaves
    /// under the head and the heading, never less than its message needs.
    private var emptyHeight: CGFloat {
        guard collectionView != nil, headerHeight > 0 else { return Self.emptyMinimum }
        let heading = SectionTitleView.barHeight(traits: traitCollection) + SectionTitleView.gapBelow(traits: traitCollection)
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top
            - collectionView.adjustedContentInset.bottom
        return max(Self.emptyMinimum, (visible - headerHeight - heading).rounded(.down))
    }

    /// The empty message's own height, at the least.
    private static let emptyMinimum: CGFloat = 220

    /// The empty card's height drawn now: a sheet that changed height, or a
    /// head that did, redraws it.
    private var drawnEmptyHeight: CGFloat = 0

    private func refillEmptyCard() {
        guard abs(emptyHeight - drawnEmptyHeight) > 0.5, dataSource.indexPath(for: .noActiveStakes) != nil else { return }
        // Out of the layout pass this is called from.
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(emptyHeight - drawnEmptyHeight) > 0.5,
                  dataSource.indexPath(for: .noActiveStakes) != nil else { return }
            var list = dataSource.snapshot()
            list.reconfigureItems([.noActiveStakes])
            dataSource.apply(list, animatingDifferences: false)
        }
    }

    /// "Active stakes ›" and "46 ♥ at stake": the heading leads to every
    /// active stake (#1477), once there is one.
    private func configureActiveHeader(_ header: WalletSectionHeader) {
        let font = UIFont.scaledMonospacedDigitSystemFont(ofSize: 13, weight: .medium, relativeTo: .footnote, maximumPointSize: 16)
        let hasStakes = stakes.contains { !$0.isSettled }
        header.onSeeAll = hasStakes ? { [weak self] in self?.openStakes(.active) } : nil
        let staked = stakes.filter { !$0.isSettled }.reduce(0) { $0 + $1.amount }
        let detail = NSMutableAttributedString()
        if staked > 0 {
            detail.append(walletAmount("\(staked)", glyph: LikesSymbol.glyphImage(), font: font, color: .secondaryLabel))
            detail.append(NSAttributedString(string: " at stake", attributes: [.font: font]))
        }
        header.configure(title: "Active stakes", detail: detail, isLink: hasStakes)
    }

    /// The soft edge under the bar: the system draws the effect under the
    /// bar it tracks.
    private func buildChrome() {
        collectionView.topEdgeEffect.style = .soft
        // Named, not searched for: the bar's edge effect reads THIS list.
        setContentScrollView(collectionView, for: .top)
    }

    /// The small detent: from the sheet's top to just under the Claim.
    /// Measured from the laid-out list rather than
    /// typed, so Dynamic Type cannot cut it.
    ///
    /// ⚠️ Every input is stable — the head's height in the list's content,
    /// the bar — never the live sheet's: re-measuring
    /// the sheet itself from layout recursed during grabber drags.
    private func updateDetent(force: Bool = false) {
        guard let sheet, dataSource != nil, let path = dataSource.indexPath(for: .header) else { return }
        if collectionView.cellForItem(at: path) == nil { collectionView.layoutIfNeeded() }
        guard let cell = collectionView.cellForItem(at: path) else { return }
        cell.layoutIfNeeded()
        // The empty card fills what is left under the head: it follows it.
        let head = cell.frame.maxY + SectionTitleView.gapAbove(traits: traitCollection)
        if abs(head - headerHeight) > 0.5 { headerHeight = head }
        refillEmptyCard()
        // ⚠️ A custom detent's height EXCLUDES the bottom safe area — the
        // sheet adds it back: the margin is what is left of the band. Read
        // from the PRESENTER's window too: this is measured in `viewDidLoad`,
        // before the sheet has a window of its own.
        let window = view.window ?? presentingViewController?.view.window
        let bottomInset = window?.safeAreaInsets.bottom ?? 0
        let height = (barClearance() + Self.topInset + cell.frame.maxY + max(Spacing.sm, Spacing.lg - bottomInset)).rounded()
        guard force || abs(height - detentHeight) > 0.5 else { return }
        detentHeight = height
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    /// The band the navigation bar takes at the sheet's top: the top safe
    /// area once laid out; before that the bar's own fitted height.
    private func barClearance() -> CGFloat {
        if view.safeAreaInsets.top > 0 { return view.safeAreaInsets.top }
        guard let bar = navigationController?.navigationBar else { return 0 }
        return bar.sizeThatFits(CGSize(width: view.bounds.width, height: 0)).height
    }

    // MARK: - Bar

    /// `[?] ······ Wallet ······ [✕]` at both heights.
    private func buildBar() {
        // Rewards, not "Wallet" (#1494): likes and gems are not money.
        title = "Rewards"
        // The likes against their cap, under the title (#1494).
        navigationItem.subtitleView = titleGauge
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.closePresentation()
        })
        close.identifier = Self.closeItemIdentifier
        close.accessibilityIdentifier = Self.closeItemIdentifier
        // How it works (#1480), whenever it is wanted again.
        let help = UIBarButtonItem(
            image: UIImage(systemName: "questionmark"),
            primaryAction: UIAction { [weak self] _ in self?.openHowItWorks() }
        )
        help.accessibilityLabel = "How it works"
        help.identifier = Self.helpItemIdentifier
        help.accessibilityIdentifier = Self.helpItemIdentifier
        navigationItem.leftBarButtonItem = help
        navigationItem.rightBarButtonItem = close
    }

    // MARK: - Navigation

    /// Pushes `controller` in the sheet AT ITS HEIGHT (#1494): collapsed
    /// stays collapsed, expanded stays expanded.
    private func pushInSheet(_ controller: UIViewController) {
        guard let navigationController, navigationController.topViewController === self else { return }
        navigationController.pushViewController(controller, animated: true)
    }

    /// How it works (#1480), pushed in the sheet.
    private func openHowItWorks() {
        guard navigationController?.topViewController === self else { return }
        WalletHowItWorks.markSeen(by: StorageScope.shared.owner)
        pushInSheet(WalletHowItWorksViewController())
    }

    /// The Stakes screen (#1477) on `segment`, pushed in the sheet: every
    /// stake by day — Settled is the history of the paid ones.
    private func openStakes(_ segment: WalletStakesViewController.Segment) {
        pushInSheet(WalletStakesViewController(
            wallet: wallet, segment: segment, posts: entries, lookUpPosts: lookUpPosts,
            imagePipeline: imagePipeline, openFeedHero: openFeedHero
        ))
    }

    /// Activity: the wallet's history, pushed in the sheet (#1478).
    private func openActivity() {
        pushInSheet(WalletHistoryViewController(wallet: wallet, filterInBar: true, deviceCache: historyCache))
    }

    /// The Shop — where the gems go, from the Shop door: this sheet comes
    /// down and the Shop is pushed on the stack under it (`StakeShop.push`).
    func openShop() {
        guard let countries, presentedViewController == nil,
              let root = view.window?.rootViewController else { return }
        StakeShop.push(
            CountryShopViewController.storefront(
                access: countries, stakePacks: stakePacks, profileItems: profileItems, themes: themes,
                media: shopMedia
            ),
            over: root
        )
    }

    private func claim() {
        claimer.claim(presentingFrom: self)
    }

    // MARK: - State

    private var headerCell: WalletHeaderCell? {
        dataSource.indexPath(for: .header).flatMap { collectionView.cellForItem(at: $0) as? WalletHeaderCell }
    }

    private func configureHeader(_ header: WalletHeaderView) {
        header.configure(with: snapshot, sellsShop: countries != nil)
        header.applyClaim(
            title: WalletClaimer.title(for: snapshot, pending: claimer.isPending),
            canClaim: snapshot.claimAvailable && !claimer.isPending
        )
    }

    /// The head's Claim: what the claim does now or when it opens. Once a
    /// second while shown (the countdown).
    private func applyClaim() {
        headerCell?.header.applyClaim(
            title: WalletClaimer.title(for: snapshot, pending: claimer.isPending),
            canClaim: snapshot.claimAvailable && !claimer.isPending
        )
    }

    private func refresh() {
        snapshot = wallet.snapshot()
        stakes = wallet.stakes()
        stakesByID = Dictionary(uniqueKeysWithValues: stakes.map { ($0.targetID, $0) })

        headerCell.map { configureHeader($0.header) }
        titleGauge.configure(with: snapshot)
        applyClaim()

        // Marked loading BEFORE the list is built, so a new stake's row
        // arrives as bones rather than as a row about nothing.
        let missing = lookUpPosts == nil ? [] : postLoads.begin(
            stakes.map(\.targetID).filter { entries[PostID($0)] == nil }
        )
        // Rows whose stake moved (settled, grew) are reconfigured in place.
        applyList(reconfiguring: Set(stakes.map(\.targetID)))
        lookUp(missing)
    }

    /// The list as it stands: the head, then the active stakes as
    /// `WalletStakeList` lays them out — the failed row at their head when a
    /// post could not be loaded, the empty row when none is active.
    /// `stakeIDs` names the stake rows to redraw in place.
    private func applyList(reconfiguring stakeIDs: Set<String>) {
        let layout = WalletStakeList(stakes: stakes, loads: postLoads)
        var list = NSDiffableDataSourceSnapshot<Section, Item>()
        list.appendSections([.top, .active])
        list.appendItems([.header], toSection: .top)
        list.appendItems(Self.preview(layout.active).map(Self.item), toSection: .active)
        let before = dataSource.snapshot()
        let previous = Set(before.itemIdentifiers)
        list.reconfigureItems(list.itemIdentifiers.filter {
            switch $0 {
            // A row's hairline follows its place: a row that became, or
            // stopped being, the card's first is redrawn too.
            case .stake(let id):
                previous.contains($0) && (stakeIDs.contains(id) || Self.isFirst($0, in: before) != Self.isFirst($0, in: list))
            // The failed row's message follows the latest answer.
            case .postsFailed: previous.contains($0)
            default: false
            }
        })
        dataSource.apply(list, animatingDifferences: collectionView.window != nil)
        // The heading's total follows the stakes.
        if let header = collectionView.supplementaryView(
            forElementKind: WalletSectionHeader.kind, at: IndexPath(item: 0, section: 1)
        ) as? WalletSectionHeader {
            configureActiveHeader(header)
        }
    }

    /// Whether `item` opens its section in `list`.
    private static func isFirst(_ item: Item, in list: NSDiffableDataSourceSnapshot<Section, Item>) -> Bool {
        guard let section = list.sectionIdentifier(containingItem: item) else { return false }
        return list.itemIdentifiers(inSection: section).first == item
    }

    /// How many active stakes the Wallet shows; the heading leads to the
    /// rest (#1477).
    static let previewCount = 3

    /// `rows` with no more than `previewCount` stakes — the failed and empty
    /// rows kept.
    private static func preview(_ rows: [WalletStakeRow]) -> [WalletStakeRow] {
        var shown = 0
        return rows.filter { row in
            guard case .stake = row else { return true }
            shown += 1
            return shown <= previewCount
        }
    }

    private static func item(_ row: WalletStakeRow) -> Item {
        switch row {
        case .stake(let id): .stake(id)
        case .noActiveStakes: .noActiveStakes
        case .postsFailed: .postsFailed
        }
    }

    // MARK: - Stakes

    /// Where `id`'s post stands, for its row. Without a lookup there is
    /// nothing to wait for: the row is drawn as it is.
    private func postPhase(for id: String) -> WalletStakePostLoads.State {
        if entries[PostID(id)] != nil || lookUpPosts == nil { return .loaded }
        return postLoads.state(of: id) ?? .loading
    }

    private func configure(_ cell: WalletStakeCell, stakeID id: String, animated: Bool) {
        guard let stake = stakesByID[id] else { return }
        cell.configure(
            stake: stake, post: entries[PostID(id)], phase: postPhase(for: id),
            now: Date(), imagePipeline: imagePipeline, animated: animated,
            verdictPending: verdictsPending
        )
    }

    /// Whether the settled stakes' outcomes are still the device's guess, the
    /// server's verdicts on their way (#1395): their rows show a bone, and
    /// the Settled header no total, until the listing lands.
    private var verdictsPending: Bool {
        wallet.awaitsServerStakes
    }

    /// Whether a tap on `id`'s row does anything: open its post, or try
    /// again when its post could not be loaded. A row on its bones does
    /// nothing, so it neither gives under the finger nor selects.
    private func isPressable(stakeID id: String) -> Bool {
        if postPhase(for: id) == .failed { return true }
        return entries[PostID(id)] != nil && openFeedHero != nil
    }

    /// Asks for the posts behind `ids` — already marked loading — and draws
    /// the answer.
    ///
    /// ⚠️ An empty answer is an answer: every post it lacks FAILED. The
    /// lookup swallows each read's error (`FeedFeature.galleryPosts`), and
    /// the sheet used to drop an empty answer and never ask again, leaving
    /// rows about nothing for its lifetime.
    private func lookUp(_ ids: [String]) {
        guard let lookUpPosts, !ids.isEmpty else { return }
        Task { [weak self] in
            let found = await lookUpPosts(ids.map { PostID($0) })
            self?.postsArrived(found, requested: ids)
        }
    }

    private func postsArrived(_ found: [PostID: GalleryPost], requested: [String]) {
        entries.merge(found) { _, new in new }
        let retryFailed = postLoads.finish(requested: requested, found: Set(found.keys.map(\.rawValue)))
        // A Try Again that failed too: the sheet's own warning, and the failed
        // row's message says it (`WalletStakesFailedCell`). No toast.
        if retryFailed, viewIfLoaded?.window != nil {
            Haptics.play(.warning)
        }
        // Visible rows are drawn HERE, outside the apply, so their bones can
        // cross-fade to the post; the apply redraws the others.
        var offscreen: Set<String> = []
        for id in requested {
            if let cell = stakeCell(for: id) {
                configure(cell, stakeID: id, animated: true)
            } else {
                offscreen.insert(id)
            }
        }
        applyList(reconfiguring: offscreen)
    }

    /// Try Again — the failed row's button, or a tap on a failed stake row:
    /// the failed posts only. Their rows go back to bones; the failed row
    /// STAYS, "Trying Again…" with its button off, so nothing below it moves
    /// (`WalletStakeList`). The top and the rest of the list are not touched.
    private func retryFailedPosts() {
        let ids = postLoads.retry()
        guard !ids.isEmpty else { return }
        var offscreen: Set<String> = []
        for id in ids {
            if let cell = stakeCell(for: id) {
                configure(cell, stakeID: id, animated: false)
            } else {
                offscreen.insert(id)
            }
        }
        applyList(reconfiguring: offscreen)
        lookUp(ids)
    }

    /// Opens the feed on the previewed stakes, from the tapped one on
    /// (`WalletStakeHero`).
    private func openFeed(fromStake id: String) {
        guard let openFeedHero else { return }
        let order = dataSource.snapshot().itemIdentifiers.compactMap { item -> String? in
            if case .stake(let stake) = item { stake } else { nil }
        }
        WalletStakeHero.open(
            stake: id, order: order, posts: entries, from: self, list: collectionView,
            cell: { [weak self] id in self?.stakeCell(for: id) }, openFeedHero: openFeedHero
        )
    }

    private func stakeCell(for id: String) -> WalletStakeCell? {
        guard let path = dataSource.indexPath(for: .stake(id)) else { return nil }
        return collectionView.cellForItem(at: path) as? WalletStakeCell
    }


    // MARK: - Clock

    /// Once a second: the claim countdown, and the active stakes' "settles
    /// in" lines. A stake that has just settled refreshes the whole sheet: it
    /// leaves the page, and the gems move with it.
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
        applyClaim()
        for cell in collectionView.visibleCells {
            guard let cell = cell as? WalletStakeCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  case .stake(let id) = dataSource.itemIdentifier(for: indexPath),
                  let stake = stakesByID[id], !stake.isSettled else { continue }
            cell.applyStatus(stake: stake, now: now)
        }
    }

    // MARK: - QA

    #if DEBUG
    /// Every hook waits for the sheet to have LANDED (in a window, no
    /// transition running), not for a guessed delay.
    private func installQAHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        let landed: @MainActor () -> Bool = { [weak self] in
            guard let self else { return true }
            return view.window != nil && transitionCoordinator == nil
                && navigationController?.transitionCoordinator == nil
        }
        // `-wallet-demo-claim`: fires the Claim once the sheet is up — the
        // real claim path minus the finger. Pair with `-open-wallet
        // -wallet-claim-ready`.
        if arguments.contains("-wallet-demo-claim") {
            QAWait.until("-wallet-demo-claim", landed) { [weak self] in self?.claim() }
        }
        // `-wallet-open-shop`: the Shop door's path, once the sheet is up.
        if arguments.contains("-wallet-open-shop") {
            QAWait.until("-wallet-open-shop", landed) { [weak self] in self?.openShop() }
        }
        // `-wallet-open-activity`: the Activity door's path.
        if arguments.contains("-wallet-open-activity") {
            QAWait.until("-wallet-open-activity", landed) { [weak self] in self?.openActivity() }
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
            growForQA()
            QAWait.until("-wallet-open-stake \(row)", { [weak self] in
                guard let self else { return true }
                guard landed(), let id = stakeID() else { return false }
                return entries[PostID(id)] != nil && stakeCell(for: id) != nil
            }) { [weak self] in
                guard let id = stakeID() else { return }
                self?.openFeed(fromStake: id)
            }
        }
        // `-wallet-open-stakes active|settled`: the Stakes screen (#1477), the
        // heading's and the Settled door's own way.
        if let index = arguments.firstIndex(of: "-wallet-open-stakes"), index + 1 < arguments.count {
            let segment: WalletStakesViewController.Segment = arguments[index + 1] == "settled" ? .settled : .active
            QAWait.until("-wallet-open-stakes", landed) { [weak self] in self?.openStakes(segment) }
        }
        // `-wallet-sheet-scroll <pt>`: grows the sheet and scrolls the list,
        // so the rows under the bar can be screenshotted.
        if let index = arguments.firstIndex(of: "-wallet-sheet-scroll"), index + 1 < arguments.count,
           let offset = Double(arguments[index + 1]) {
            growForQA()
            QAWait.until("-wallet-sheet-scroll", landed) { [weak self] in
                guard let collection = self?.collectionView else { return }
                collection.setContentOffset(
                    CGPoint(x: 0, y: offset - collection.adjustedContentInset.top), animated: true
                )
            }
        }
    }

    /// The large height, for a hook that needs the rows below the top.
    private func growForQA() {
        QAWait.until("-wallet grow", { [weak self] in self?.sheet != nil }) { [weak self] in
            guard let self, let sheet else { return }
            expand(sheet)
        }
    }
    #endif
}

extension WalletSheetViewController: UICollectionViewDelegate {
    /// A stake row opens its post, or tries again when its post could not be
    /// loaded; nothing else on the list is pressable (the head has its own
    /// controls).
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .stake(let id): isPressable(stakeID: id)
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .stake(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        if postPhase(for: id) == .failed {
            retryFailedPosts()
        } else {
            openFeed(fromStake: id)
        }
    }
}

extension WalletSheetViewController: UISheetPresentationControllerDelegate {
    // Pulled up (or scrolled) to large, the sheet keeps both detents (#1732):
    // nothing to do on a detent change any more.
}

/// Holds notification tokens and unregisters them on its own deallocation
/// (when the owning sheet is released). `@unchecked Sendable` so its deinit
/// may run off the main actor; `removeObserver` is itself thread-safe, and
/// the tokens are only written on the main actor at setup time. `nonisolated`,
/// because the App target's default-MainActor isolation would otherwise pin
/// `tokens` to the main actor and put it out of deinit's reach.
nonisolated final class WalletObserverTokenBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
