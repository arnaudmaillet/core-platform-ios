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

/// The Wallet hub (#1476, structure B, the owner 2026-10-18): pushed from
/// the Claim sheet's Wallet row (`WalletClaimSheetViewController`), in the
/// same sheet, which grows to its large detent for it.
///
/// # The economy it shows (`dev/economy/`, charter V5.3)
///   • **Likes** (currency A, the heart) — curation capacity: claimed, spent
///     by STAKING on posts;
///   • **Gems** (currency B, the diamond) — earned-only: what a stake pays
///     once it SETTLES, if it turned out to carry information. Settlement is
///     deferred by design, so a stake is ACTIVE for a while before it has an
///     outcome.
///
/// # Anatomy, top to bottom
///   • the HEADER (`WalletHubHeaderView`) — one big likes balance, four round
///     actions (Claim, Stake, Shop, Activity), and the Gems card;
///   • ACTIVE STAKES — a preview: the newest few, each post, the likes on
///     it, and how long until it settles;
///   • SETTLED — a preview: each post and its outcome.
/// Each heading is a link to the Stakes screen (#1477), every stake by day.
///
/// Its ground is the SYSTEM's large sheet (opaque), so the view is clear and
/// paints nothing of its own; the list passes under the bar through the
/// system's soft scroll-edge effect.
///
/// Everything derives from one `WalletSnapshot` and one `stakes()` reading per
/// refresh; the only per-second work is the claim countdown and the active
/// stakes' "settles in" lines.
final class WalletHubViewController: UIViewController {
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
    /// The account's countries — what the Shop sells. Nil hides the Shop item
    /// (the fleet, until the backend carries unlocks).
    private let countries: (any CountryAccess)?
    /// The Shop's Boosts — the ×100 cartridge pack. Nil sells none.
    private let stakePacks: (any StakePackSelling)?
    private let profileItems: (any ProfileItemSelling)?
    /// The Shop's Themes (#1379). Nil sells none.
    private let themes: (any ThemeSelling)?

    private nonisolated enum Section: Hashable { case header, active, settled }
    private nonisolated enum Item: Hashable {
        case header
        case stake(String)
        case noActiveStakes
        case postsFailed
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private weak var headerCell: WalletHubHeaderCell?
    /// The claim — the Claim sheet's own, so a claim on its way shows on both.
    private let claimer: WalletClaimer

    private var snapshot: WalletSnapshot
    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: GalleryPost] = [:]
    /// Where each stake's post lookup stands — what its row draws (bones,
    /// the post, or "couldn't load") and whether the failed row shows (#834).
    private var postLoads = WalletStakePostLoads()

    private var countdownTimer: Timer?
    private let walletObservers = WalletObserverTokenBag()

    /// Room under the bar before the header starts.
    private static let topInset: CGFloat = Spacing.sm

    /// Stable identifiers: a reused bar item identifier is how iOS 26 matches
    /// an item across a reinstall.
    static let closeItemIdentifier = "wallet.hub.close"

    /// The Shop's posters and preview loops (#1075).
    private let shopMedia: ShopMedia?

    init(
        wallet: WalletStore,
        claimer: WalletClaimer,
        lookUpPosts: PostLookup? = nil,
        imagePipeline: ImagePipeline? = nil,
        openFeedHero: OpenFeedHero? = nil,
        countries: (any CountryAccess)? = nil,
        stakePacks: (any StakePackSelling)? = nil,
        profileItems: (any ProfileItemSelling)? = nil,
        themes: (any ThemeSelling)? = nil,
        shopMedia: ShopMedia? = nil
    ) {
        self.shopMedia = shopMedia
        self.claimer = claimer
        self.openFeedHero = openFeedHero
        self.countries = countries
        self.stakePacks = stakePacks
        self.profileItems = profileItems
        self.themes = themes
        self.wallet = wallet
        self.lookUpPosts = lookUpPosts
        self.imagePipeline = imagePipeline
        self.snapshot = wallet.snapshot()
        super.init(nibName: nil, bundle: nil)
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

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // Every hook below waits for the sheet to have LANDED (in a window,
        // no transition running), not for a guessed delay.
        let landed: @MainActor () -> Bool = { [weak self] in
            guard let self else { return true }
            return view.window != nil && transitionCoordinator == nil
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
        // `-wallet-open-stakes active|settled`: the Stakes screen (#1477), the
        // headings' own way.
        if let index = arguments.firstIndex(of: "-wallet-open-stakes"), index + 1 < arguments.count {
            let segment: WalletStakesViewController.Segment = arguments[index + 1] == "settled" ? .settled : .active
            QAWait.until("-wallet-open-stakes", landed) { [weak self] in self?.openStakes(segment) }
        }
        // `-wallet-sheet-scroll <pt>`: scrolls the list, so the rows under
        // the bar can be screenshotted.
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

    // MARK: - Layout

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index) ?? .header
            let traits = environment.traitCollection
            // Every section is followed by a titled one but the last: it
            // leaves the app's one section gap under it (`Spacing.section` to
            // the next title's line, the title bar's own air counted in).
            let isLast = index == (self?.dataSource?.snapshot().numberOfSections ?? 1) - 1
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
                top: section == .header ? 0 : SectionTitleView.gapBelow(traits: traits),
                leading: margin,
                bottom: isLast ? 0 : SectionTitleView.gapAbove(traits: traits),
                trailing: margin
            )
            if section != .header {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(SectionTitleView.barHeight(traits: traits))
                    ),
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
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let headerRegistration = UICollectionView.CellRegistration<WalletHubHeaderCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            configureHeader(cell.header)
            headerCell = cell
        }
        let stakeRegistration = UICollectionView.CellRegistration<WalletStakeCell, Item> { [weak self] cell, _, item in
            guard let self, case .stake(let id) = item else { return }
            // Inside the apply: never animated (it would be swallowed). A post
            // landing on a visible row is cross-faded by `postsArrived`.
            configure(cell, stakeID: id, animated: false)
        }
        let emptyRegistration = UICollectionView.CellRegistration<WalletEmptyStakesCell, Item> { _, _, _ in }
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
        ) { [weak self] header, _, indexPath in
            guard let self, let section = dataSource.sectionIdentifier(for: indexPath.section) else { return }
            configure(header, for: section)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeaderRegistration, for: indexPath)
        }
    }

    private func configure(_ header: WalletSectionHeader, for section: Section) {
        // Each heading leads to every stake of its kind (#1477), once there
        // is one.
        let segment: WalletStakesViewController.Segment? = switch section {
        case .header: nil
        case .active: .active
        case .settled: .settled
        }
        if let segment {
            let hasStakes = stakes.contains { $0.isSettled == (segment == .settled) }
            header.onSeeAll = hasStakes ? { [weak self] in self?.openStakes(segment) } : nil
        }
        let font = UIFont.scaledMonospacedDigitSystemFont(ofSize: 13, weight: .medium, relativeTo: .footnote, maximumPointSize: 16)
        switch section {
        case .header:
            break
        case .active:
            let staked = stakes.filter { !$0.isSettled }.reduce(0) { $0 + $1.amount }
            let detail = NSMutableAttributedString()
            if staked > 0 {
                detail.append(walletAmount("\(staked)", glyph: LikesSymbol.glyphImage(), font: font, color: .secondaryLabel))
                detail.append(NSAttributedString(string: " at stake", attributes: [.font: font]))
            }
            header.configure(title: "Active stakes", detail: detail, isLink: header.onSeeAll != nil)
        case .settled:
            // The sum of the gem amounts the rows SHOW (#1395): none while
            // their outcomes are bones (`verdictsPending`).
            let earned = verdictsPending ? 0 : stakes.reduce(0) { $0 + $1.gems }
            // The server's settlement credits no gems yet (shadow mode,
            // #903): a total of none is not shown as "+0".
            guard earned > 0 else {
                header.configure(title: "Settled", detail: NSAttributedString(), isLink: header.onSeeAll != nil)
                return
            }
            let detail = NSMutableAttributedString(attributedString: walletAmount(
                "+\(earned)", glyph: GemSymbol.glyphImage(), font: font, color: GemSymbol.tint
            ))
            detail.append(NSAttributedString(string: " earned", attributes: [.font: font]))
            header.configure(title: "Settled", detail: detail, isLink: header.onSeeAll != nil)
        }
    }

    /// The soft edge under the bar: the system draws the effect under the
    /// bar it tracks.
    private func buildChrome() {
        collectionView.topEdgeEffect.style = .soft
        // Named, not searched for: the bar's edge effect reads THIS list.
        setContentScrollView(collectionView, for: .top)
    }

    // MARK: - Bar

    /// `‹ ······ Wallet ······ [✕]`: back to the Claim sheet, or close.
    private func buildBar() {
        title = "Wallet"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.identifier = Self.closeItemIdentifier
        close.accessibilityIdentifier = Self.closeItemIdentifier
        navigationItem.rightBarButtonItem = close
    }

    /// The Shop — where the gems go. A pushed screen since 2026-10-13: this
    /// sheet comes down and the Shop is pushed on the stack under it
    /// (`StakeShop.push`).
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

    // MARK: - State

    private func configureHeader(_ header: WalletHubHeaderView) {
        header.configure(
            with: snapshot, claimTitle: WalletClaimer.title(for: snapshot, pending: claimer.isPending),
            canClaim: snapshot.claimAvailable && !claimer.isPending, sellsShop: countries != nil
        )
        header.onClaim = { [weak self] in
            guard let self else { return }
            claimer.claim(presentingFrom: self)
        }
        header.onStake = { [weak self] in self?.openStakes(.active) }
        header.onShop = { [weak self] in self?.openShop() }
        header.onActivity = { [weak self] in self?.openActivity() }
        header.onGems = { [weak self] in self?.openShop() }
    }

    /// The Stakes screen (#1477) on `segment`, pushed in the sheet: every
    /// stake by day. Stake opens it on Active — where staking shows (staking
    /// itself is a like on a post, in the feeds).
    private func openStakes(_ segment: WalletStakesViewController.Segment) {
        navigationController?.pushViewController(
            WalletStakesViewController(
                wallet: wallet, segment: segment, posts: entries, lookUpPosts: lookUpPosts,
                imagePipeline: imagePipeline, openFeedHero: openFeedHero
            ),
            animated: true
        )
    }

    /// Activity: the wallet's history, pushed in the sheet (slice 4 groups
    /// it by day, #1478).
    private func openActivity() {
        navigationController?.pushViewController(WalletHistoryViewController(wallet: wallet), animated: true)
    }

    private func refresh() {
        snapshot = wallet.snapshot()
        stakes = wallet.stakes()
        stakesByID = Dictionary(uniqueKeysWithValues: stakes.map { ($0.targetID, $0) })

        headerCell.map { configureHeader($0.header) }

        // Marked loading BEFORE the list is built, so a new stake's row
        // arrives as bones rather than as a row about nothing.
        let missing = lookUpPosts == nil ? [] : postLoads.begin(
            stakes.map(\.targetID).filter { entries[PostID($0)] == nil }
        )
        // Rows whose stake moved (settled, grew) are reconfigured in place.
        applyList(reconfiguring: Set(stakes.map(\.targetID)))
        lookUp(missing)
    }

    /// The list as it stands: the header, then the stakes as
    /// `WalletStakeList` lays them out — the failed row at their head when a
    /// post could not be loaded, the empty card when no stake is active.
    /// `stakeIDs` names the stake rows to redraw in place.
    private func applyList(reconfiguring stakeIDs: Set<String>) {
        let layout = WalletStakeList(stakes: stakes, loads: postLoads)
        var list = NSDiffableDataSourceSnapshot<Section, Item>()
        list.appendSections([.header, .active])
        list.appendItems([.header], toSection: .header)
        list.appendItems(Self.preview(layout.active).map(Self.item), toSection: .active)
        if let settled = layout.settled {
            list.appendSections([.settled])
            list.appendItems(Self.preview(settled).map(Self.item), toSection: .settled)
        }
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        list.reconfigureItems(list.itemIdentifiers.filter {
            switch $0 {
            case .stake(let id): stakeIDs.contains(id) && previous.contains($0)
            // The failed row's message follows the latest answer.
            case .postsFailed: previous.contains($0)
            default: false
            }
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
    }

    /// How many stakes each section previews; its heading leads to the rest
    /// (#1477).
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
            pressable: isPressable(stakeID: id), now: Date(), imagePipeline: imagePipeline, animated: animated,
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
            HapticNotification().notificationOccurred(.warning)
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
    /// (`WalletStakeList`). The header and the rest of the list are not
    /// touched.
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

    // MARK: - Opening a stake

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
        headerCell?.header.applyClaim(
            title: WalletClaimer.title(for: snapshot, pending: claimer.isPending),
            canClaim: snapshot.claimAvailable && !claimer.isPending
        )
        for cell in collectionView.visibleCells {
            guard let cell = cell as? WalletStakeCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  case .stake(let id) = dataSource.itemIdentifier(for: indexPath),
                  let stake = stakesByID[id], !stake.isSettled else { continue }
            cell.applyStatus(stake: stake, now: now)
        }
    }
}

extension WalletHubViewController: UICollectionViewDelegate {
    /// A stake row opens its post, or tries again when its post could not be
    /// loaded; nothing else on the list is pressable (the failed row has its
    /// own button).
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .stake(let id): isPressable(stakeID: id)
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard case .stake(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        if postPhase(for: id) == .failed {
            retryFailedPosts()
        } else {
            openFeed(fromStake: id)
        }
    }
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
