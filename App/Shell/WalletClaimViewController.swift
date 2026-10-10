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
///   • the BAR — `[storefront Shop] ······ [✕]`: the Shop (what the gems buy,
///     presented as a sheet OVER this one, so closing it comes back here) and
///     the close button, plain bar items the system draws in glass;
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
/// paints nothing of its own. The summary scrolls away with the list and
/// nothing replaces it: the compact balances that used to fade in under the
/// grabber went when the bar took that band (2026-10-01).
///
/// # The edges
/// The list passes under the bar and the Claim button through the system's
/// own SOFT scroll-edge effect — a blur that ramps in strength rather than a
/// material faded by a mask. The hand-built material blurs this replaced read
/// as two frosted slabs: "beaucoup trop opaque, on n'aperçoit pas la
/// collection view".
///
/// # Presented in its own navigation stack
/// The bar is a navigation bar, so the sheet is this screen as the root of a
/// navigation controller (`wrappedInSheet()`), and the sheet's configuration
/// lives on THAT controller's presentation — the one presented.
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
    /// A guest's sheet shows the welcome gift instead of the device's wallet
    /// (guest mode decision 11); nil shows the wallet to everyone.
    private let welcome: WalletBadgeInstaller.WelcomeGiftFace?
    private let lookUpPosts: PostLookup?
    private let imagePipeline: ImagePipeline?
    private let openFeedHero: OpenFeedHero?
    /// The account's countries — what the Shop sells. Nil hides the Shop item
    /// (the fleet, until the backend carries unlocks).
    private let countries: (any CountryAccess)?
    /// The Shop's Boosts — the ×100 cartridge pack. Nil sells none.
    private let stakePacks: (any StakePackSelling)?

    private nonisolated enum Section: Hashable { case summary, active, settled }
    private nonisolated enum Item: Hashable {
        case summary
        case stake(String)
        case noActiveStakes
        case postsFailed
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private weak var summaryCell: WalletSummaryCell?
    private let claimButton = UIButton(configuration: .prominentGlass())
    /// The Claim button's container, registered with the list's BOTTOM scroll
    /// edge so the system's soft edge effect grows to sit behind it.
    private let claimBar = UIView()

    private var snapshot: WalletSnapshot
    private var stakes: [WalletStake] = []
    private var stakesByID: [String: WalletStake] = [:]
    private var entries: [PostID: GalleryPost] = [:]
    /// Where each stake's post lookup stands — what its row draws (bones,
    /// the post, or "couldn't load") and whether the failed row shows (#834).
    private var postLoads = WalletStakePostLoads()

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

    /// Room under the bar before the summary starts.
    private static let topInset: CGFloat = Spacing.sm

    /// Stable identifiers for the bar items: a reused identifier is how
    /// iOS 26 matches an item across a reinstall.
    static let shopItemIdentifier = "wallet.shop"
    static let closeItemIdentifier = "wallet.close"

    init(
        wallet: WalletStore,
        lookUpPosts: PostLookup? = nil,
        imagePipeline: ImagePipeline? = nil,
        openFeedHero: OpenFeedHero? = nil,
        countries: (any CountryAccess)? = nil,
        stakePacks: (any StakePackSelling)? = nil,
        welcome: WalletBadgeInstaller.WelcomeGiftFace? = nil
    ) {
        self.welcome = welcome
        self.openFeedHero = openFeedHero
        self.countries = countries
        self.stakePacks = stakePacks
        self.wallet = wallet
        self.lookUpPosts = lookUpPosts
        self.imagePipeline = imagePipeline
        self.snapshot = wallet.snapshot()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet as it is presented: this screen as the root of a navigation
    /// controller that shows its bar (the Shop and close items), set up as a
    /// page sheet with the small and large detents.
    ///
    /// ⚠️ The sheet's configuration lives on the NAVIGATION controller's
    /// presentation — the one presented — and every read of it below goes
    /// through `sheet`.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [
                .custom(identifier: Self.smallDetent) { [weak self] _ in self?.smallDetentHeight ?? 460 },
                .large(),
            ]
            // ⚠️ OPENS SMALL; a scroll up grows it (see the type's note).
            sheet.selectedDetentIdentifier = Self.smallDetent
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            // ⚠️ NO `preferredCornerRadius`: UIKit's own. A radius set here and
            // then corrected to the device's on the first layout visibly
            // popped from one to the other as the sheet rose.
        }
        return navigation
    }

    /// The presented sheet — the navigation controller's.
    private var sheet: UISheetPresentationController? {
        navigationController?.sheetPresentationController
    }

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

        walletObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ] + (welcome.map { welcome in
            // A guest's sheet follows the gift and the viewer: signing up from
            // here turns it into the member's wallet, the gift credited.
            [
                NotificationCenter.default.addObserver(
                    forName: WelcomeGift.didChangeNotification, object: welcome.gift, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                },
                NotificationCenter.default.addObserver(
                    forName: .viewerDidChange, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                },
            ]
        } ?? [])
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
                guard let sheet = self?.sheet else { return }
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            }
        }
        // `-wallet-open-shop`: the Shop item's own path, once the sheet is up.
        if arguments.contains("-wallet-open-shop") {
            QAWait.until("-wallet-open-shop", landed) { [weak self] in self?.openShop() }
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
        // `-wallet-sheet-scroll <pt>`: scrolls the list, so the rows under
        // the bar can be screenshotted. Pair with `-wallet-sheet-large`.
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
        applyButtonMargins()
        updateSmallDetent()
    }

    // MARK: - Layout

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index) ?? .summary
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
                top: section == .summary ? 0 : SectionTitleView.gapBelow(traits: traits),
                leading: margin,
                bottom: isLast ? 0 : SectionTitleView.gapAbove(traits: traits),
                trailing: margin
            )
            if section != .summary {
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
            // To the sheet's foot: the list passes UNDER the Claim button's
            // blur rather than ending above it.
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let summaryRegistration = UICollectionView.CellRegistration<WalletSummaryCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            configureSummary(cell.summary)
            summaryCell = cell
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
            cell.configure(failedAfterRetry: postLoads.failedAfterRetry)
            cell.onRetry = { [weak self] in self?.retryFailedPosts() }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .summary:
                collectionView.dequeueConfiguredReusableCell(using: summaryRegistration, for: indexPath, item: item)
            case .stake:
                collectionView.dequeueConfiguredReusableCell(using: stakeRegistration, for: indexPath, item: item)
            case .noActiveStakes:
                collectionView.dequeueConfiguredReusableCell(using: emptyRegistration, for: indexPath, item: item)
            case .postsFailed:
                collectionView.dequeueConfiguredReusableCell(using: failedRegistration, for: indexPath, item: item)
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
        let font = UIFont.scaledMonospacedDigitSystemFont(ofSize: 13, weight: .medium, relativeTo: .footnote, maximumPointSize: 16)
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

    /// The soft edges, and the Claim button above the list — its container
    /// registered with the list's bottom scroll edge, so the system draws the
    /// soft edge effect behind it (`UIScrollEdgeElementContainerInteraction`).
    /// The top edge is the navigation bar's: the system draws the effect
    /// under the bar it tracks.
    private func buildChrome() {
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
        // Named, not searched for: the bar's edge effect reads THIS list.
        setContentScrollView(collectionView, for: .top)

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

    /// Nests the button in the screen's bottom corners — which the sheet's
    /// bottom edge follows whatever its own radius: margin = device radius −
    /// capsule radius on all three edges, so the pill stays concentric with
    /// the corners on every screen. The sheet keeps UIKit's radius (see init).
    private func applyButtonMargins() {
        guard view.window != nil else { return }
        let device = ScreenGeometry.cornerRadius(behind: view)
        guard device > 0, abs(device - appliedSheetRadius) > 0.5 else { return }
        appliedSheetRadius = device
        buttonMargin = max(WalletSheetMetrics.sideMargin, device - WalletSheetMetrics.claimHeight / 2)
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
        guard let sheet,
              sheet.detents.contains(where: { $0.identifier == Self.smallDetent }) else { return }
        var bottom: CGFloat?
        let rows = dataSource.snapshot().itemIdentifiers
            .filter { $0 != .summary }.prefix(Self.smallDetentRows)
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
        let height = (barClearance() + Self.topInset + bottom + Spacing.xl + WalletSheetMetrics.claimHeight
            + buttonMargin - bottomInset).rounded()
        guard abs(height - smallDetentHeight) > 0.5 else { return }
        smallDetentHeight = height
        sheet.invalidateDetents()
    }

    /// The band the navigation bar takes at the sheet's top, which the list
    /// starts under: the top safe area once laid out; before that (the first
    /// measure, in `viewDidLoad`) the bar's own fitted height, so the sheet
    /// does not present at a guess and then jump to the answer.
    private func barClearance() -> CGFloat {
        if view.safeAreaInsets.top > 0 { return view.safeAreaInsets.top }
        guard let bar = navigationController?.navigationBar else { return 0 }
        return bar.sizeThatFits(CGSize(width: view.bounds.width, height: 0)).height
    }

    // MARK: - Bar

    /// `[storefront Shop] ······ [✕]` — no title: the summary under it says
    /// what the sheet is.
    private func buildBar() {
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.identifier = Self.closeItemIdentifier
        close.accessibilityIdentifier = Self.closeItemIdentifier
        navigationItem.rightBarButtonItem = close
        if countries != nil {
            navigationItem.leftBarButtonItem = makeShopItem()
        }
    }

    /// The Shop: the store's own glyph (`CountryShopEntry.symbolName`, the
    /// Explore header's door) AND its name. A stock bar item draws one or the
    /// other, never both, so it is a PLAIN button as the item's custom view —
    /// no material of its own, the bar's glass is the only capsule (a glass
    /// button inside would stack a second one).
    private func makeShopItem() -> UIBarButtonItem {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: CountryShopEntry.symbolName)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 15, weight: .semibold
        )
        configuration.title = CountryShopEntry.title
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaledSystemFont(
                ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 22
            )
            return attributes
        }
        let button = UIButton(configuration: configuration)
        // The Explore header's door is also "Shop": the identifier tells
        // the two apart in the accessibility tree.
        button.accessibilityIdentifier = Self.shopItemIdentifier
        button.addAction(UIAction { [weak self] _ in self?.openShop() }, for: .primaryActionTriggered)
        button.sizeToFit()
        let item = UIBarButtonItem(customView: button)
        item.identifier = Self.shopItemIdentifier
        item.accessibilityLabel = CountryShopEntry.title
        return item
    }

    /// The Shop, as a sheet OVER this one — where the gems go; closing it
    /// comes back to the balance they came from.
    func openShop() {
        guard let countries, presentedViewController == nil else { return }
        present(CountryShopViewController.sheet(access: countries, stakePacks: stakePacks), animated: true)
    }

    // MARK: - State

    /// The welcome gift a guest is looking at — nil for a member (or a sheet
    /// built without one). `lockedAmount` is nil once this device's gift is
    /// spent, and a guest then sees 0: never a wallet that isn't theirs.
    private var guestGift: Int? {
        guard let welcome, !welcome.gate.isMember else { return nil }
        return welcome.gift.lockedAmount ?? 0
    }

    private func configureSummary(_ summary: WalletSummaryView) {
        if let guestGift {
            summary.configure(guestGift: guestGift, dailyClaimCap: snapshot.dailyClaimCap)
        } else {
            summary.configure(with: snapshot)
        }
    }

    private func refresh() {
        snapshot = wallet.snapshot()
        // A guest has no stakes: the device's are someone else's.
        stakes = guestGift == nil ? wallet.stakes() : []
        stakesByID = Dictionary(uniqueKeysWithValues: stakes.map { ($0.targetID, $0) })

        summaryCell.map { configureSummary($0.summary) }
        applyClaimButtonState()

        // Marked loading BEFORE the list is built, so a new stake's row
        // arrives as bones rather than as a row about nothing.
        let missing = lookUpPosts == nil ? [] : postLoads.begin(
            stakes.map(\.targetID).filter { entries[PostID($0)] == nil }
        )
        // Rows whose stake moved (settled, grew) are reconfigured in place.
        applyList(reconfiguring: Set(stakes.map(\.targetID)))
        lookUp(missing)
    }

    /// The list as it stands: the summary, then the stakes as
    /// `WalletStakeList` lays them out — the failed row at their head when a
    /// post could not be loaded, the empty card when no stake is active.
    /// `stakeIDs` names the stake rows to redraw in place.
    private func applyList(reconfiguring stakeIDs: Set<String>) {
        let layout = WalletStakeList(stakes: stakes, loads: postLoads)
        var list = NSDiffableDataSourceSnapshot<Section, Item>()
        list.appendSections([.summary, .active])
        list.appendItems([.summary], toSection: .summary)
        list.appendItems(layout.active.map(Self.item), toSection: .active)
        if let settled = layout.settled {
            list.appendSections([.settled])
            list.appendItems(settled.map(Self.item), toSection: .settled)
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
            now: Date(), imagePipeline: imagePipeline, animated: animated
        )
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
        if retryFailed {
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

    /// The failed row's Try Again: the failed posts only — their rows go back
    /// to bones and the failed row leaves until the answer. The summary and
    /// the rest of the list are not touched.
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

    private func applyClaimButtonState() {
        // A guest's Claim is the lock: always pressable, and pressing it asks
        // them to sign up for the gift it names.
        if let guestGift {
            claimButton.isEnabled = true
            var title = AttributedString("Claim \(guestGift) likes")
            title.font = .scaledMonospacedDigitSystemFont(
                ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 24
            )
            claimButton.configuration?.attributedTitle = title
            claimButton.configuration?.image = UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            )
            claimButton.configuration?.imagePadding = Spacing.sm
            claimButton.accessibilityHint = "Sign up to claim them"
            return
        }
        claimButton.configuration?.image = nil
        claimButton.accessibilityHint = nil
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
        title.font = .scaledMonospacedDigitSystemFont(
            ofSize: 17, weight: .semibold, relativeTo: .headline, maximumPointSize: 24
        )
        claimButton.configuration?.attributedTitle = title
    }

    private func claimTapped() {
        // A guest claims the gift by signing up: the sign-in itself credits it
        // (`AppCoordinator.render`), so there is no claim to commit after —
        // committing one would pay the hourly claim on top.
        if let welcome, guestGift != nil {
            Task { @MainActor [weak self] in
                guard await welcome.gate.requireMember(for: .claim), let self else { return }
                HapticNotification().notificationOccurred(.success)
                refresh()
                summaryCell?.summary.pointsTile.pop()
            }
            return
        }
        MemberGates.perform(.claim, from: self) { [weak self] in self?.commitClaim() }
    }

    private func commitClaim() {
        switch wallet.claim() {
        case .claimed:
            HapticNotification().notificationOccurred(.success)
            // Explicit refresh, not the observer's: its queue hop is UIKit's
            // business, and the pop below must scale the NEW number.
            refresh()
            summaryCell?.summary.pointsTile.pop()
        case .tooEarly, .dailyCapReached:
            HapticNotification().notificationOccurred(.warning)
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
    /// animation (`OverSheetFeedHost`), the feed is pushed onto IT, and the flight
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

        OverSheetFeedHost.present(over: self) { host in
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
    /// A stake row opens its post; nothing else on the list is pressable.
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .stake(let id): entries[PostID(id)] != nil && openFeedHero != nil
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if case .stake(let id) = dataSource.itemIdentifier(for: indexPath) {
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
private nonisolated final class WalletObserverTokenBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
