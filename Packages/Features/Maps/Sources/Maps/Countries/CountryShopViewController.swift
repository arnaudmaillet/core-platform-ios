import DesignSystem
import MapsInterface
import UIKit
import CoreModels
import CoreNavigation

/// Every country, and unlocking them: the Shop behind the Explore header's
/// storefront and the wallet sheet's Shop item.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ (‹)            Shop          (◆ 100) │
///  │ Boosts                               │
///  │ (⚡) ×100 cartridges           [◆ 50] │  ← or "Active — 2 left"
///  │      3 shots · 100 points a tap      │
///  │ Your map        3 of 237 countries   │  ← scrolls with the list
///  │ ▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
///  │ Unlocked 3                           │
///  │ 🇫🇷 France                     Home   │
///  │ 🇺🇸 United States          ✓ Unlocked │
///  │ Locked 234                           │
///  │ 🇪🇸 Spain                             │
///  │    #4 · ♥ 12.4K · 86 posts    [◆ 50] │
///  │ ( 🔍 Search countries              ) │  ← the toolbar's
///  └──────────────────────────────────────┘
/// ```
///
/// # Boosts, then the map
/// With a `StakePackSelling`, the list opens on **Boosts**: the ×100 cartridge
/// pack — shots that each stake 100 of the viewer's own points in one tap,
/// bought with gems. First, because it is one row the collapsed sheet always
/// shows (under 237 countries it would be out of reach), and because the
/// stake menu's "Get ×100 cartridges in the Shop" OPENS the Shop here
/// (`Focus.boosts`: the row flashes once the sheet is up). Packs don't
/// stack: while one has shots, the row says "Active — N left" in place of a
/// price. A price raises a one-line confirmation menu (the pack is bought on
/// the spot, there is no offer screen to show). A search is a search of
/// countries, so it hides Boosts.
///
/// # One list, two sections
/// The progress block leads the countries — it is an ITEM, so it scrolls
/// away with the rows rather than standing over them. Then **Unlocked** (the
/// home country first, then by rank) and **Locked** (by rank), each header
/// the app's one section title carrying its count (`SectionTitleView`). Search filters both sections at once; a section left
/// empty by it is dropped, and nothing left at all is the system's search
/// empty state. An unlock moves its row from Locked to Unlocked, animated.
///
/// The rank is what prices a country (`CountryStanding.price(forRank:)`). A
/// price opens the same offer the map makes (`CountryUnlockSheetViewController`),
/// so buying reads the same from both doors. Opened from the map, a row also
/// takes you TO the country (`onShowCountry`); opened from the wallet, there
/// is no map to show it on.
///
/// # A plain list under the system's soft edge
/// The collection view is the sheet's whole content, edge to edge, and a
/// PLAIN list: rows run the sheet's full width on its standard margins, with
/// inset separators — no inset-grouped card around each section, whose own
/// margins doubled the sheet's (2026-10-01). The bar — the back button, the
/// title, the gems on the right — and the search field float over
/// it, and the rows passing under them soften into UIKit's own SOFT top edge
/// effect: a progressive blur, the one exception (with the notifications
/// drawer and the sound sheet's gallery) to the app's bare headers
/// (`prefersClearTopEdge`), asked for on 2026-10-01. The bar items are plain
/// bar items, so the system draws their glass.
///
/// # A pushed screen
/// Countries' See all under the storefront (#1075), pushed with no tab bar:
/// the back button, the gems on the right, and the system's search field at
/// the BOTTOM, in the toolbar (owner, 2026-10-13 — it was a sheet with a
/// close button and the field under the title).
public final class CountryShopViewController: UIViewController {
    /// Shows a country on the map. Nil hides the "show" half of a row's tap.
    public var onShowCountry: ((String) -> Void)?

    /// What the Shop was opened FOR, beyond browsing.
    public enum Focus: Sendable {
        /// The cartridge pack: the stake menu's empty-pack row opens the Shop
        /// on it. Boosts already lead the list; the row flashes once the
        /// sheet is up, so the eye lands on it.
        case boosts
    }
    /// Nil: opened to browse (the Explore header, the points sheet).
    public private(set) var focus: Focus?
    /// The focus is shown once, on the first appearance.
    private var hasShownFocus = false

    enum Section: Hashable { case boosts, progress, unlocked, locked }
    enum Item: Hashable {
        /// The ×100 cartridge pack, Boosts' one row.
        case stakePack
        /// "Your map · N of 237", the first item of the list.
        case progress
        case country(String)
    }

    /// Stable identifiers for the bar items: a reused identifier is how
    /// iOS 26 matches an item across a reinstall.
    static let balanceItemIdentifier = "shop.balance"

    private let access: any CountryAccess
    /// What Boosts sells; nil shows no Boosts section.
    private let stakePacks: (any StakePackSelling)?
    private let atlas: CountryAtlas
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var query = ""
    private var flags: [String: UIImage] = [:]

    public init(
        access: any CountryAccess, stakePacks: (any StakePackSelling)? = nil, atlas: CountryAtlas = .shared
    ) {
        self.access = access
        self.stakePacks = stakePacks
        self.atlas = atlas
        super.init(nibName: nil, bundle: nil)
        title = CountryShopEntry.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The Shop: the storefront (#1075), PUSHED on the stack it is opened
    /// from — a screen of its own with a back button and no tab bar, not a
    /// sheet (owner, 2026-10-13). The country list is its Countries See all.
    public static func storefront(
        access: any CountryAccess, stakePacks: (any StakePackSelling)? = nil,
        focus: Focus? = nil,
        media: ShopMedia? = nil,
        onShowCountry: ((String) -> Void)? = nil
    ) -> UIViewController {
        let shop = ShopStorefrontViewController(access: access, stakePacks: stakePacks, media: media)
        shop.focus = focus
        shop.onShowCountry = onShowCountry
        return shop
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        // A pushed screen's own ground (it was a sheet's glass until
        // 2026-10-13).
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search countries"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        // The field at the BOTTOM, the system's own (owner, 2026-10-13): iOS
        // 26 puts an integrated search in the toolbar, where the thumb is.
        navigationItem.preferredSearchBarPlacement = .integrated
        navigationItem.searchBarPlacementAllowsToolbarIntegration = true
        toolbarItems = [navigationItem.searchBarPlacementBarButtonItem]

        // The whole sheet: the bar and the search field float over it.
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // The system's progressive blur under the bar and the search field
        // (see the type's note). STATED rather than left `.automatic`: under
        // a titled bar the automatic style is the tinted frost over the whole
        // header that the app rejected (2026-09-22).
        collectionView.topEdgeEffect.style = .soft
        view.addSubview(collectionView)
        collectionView.pin(to: view)
        // Named, not searched for: the effect is drawn where the bar meets
        // the scroll view it TRACKS, and the empty state is a sibling.
        setContentScrollView(collectionView, for: .top)

        let progressRegistration = UICollectionView.CellRegistration<CountryShopProgressCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            let (owned, total) = ownedAndTotal()
            cell.configure(owned: owned, total: total, animated: false)
        }
        let countryRegistration = UICollectionView.CellRegistration<CountryShopRowCell, String> {
            [weak self] cell, _, code in self?.configure(cell, code: code)
        }
        let packRegistration = UICollectionView.CellRegistration<StakePackRowCell, Item> {
            [weak self] cell, _, _ in self?.configure(cell)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            switch item {
            case .stakePack:
                view.dequeueConfiguredReusableCell(using: packRegistration, for: path, item: item)
            case .progress:
                view.dequeueConfiguredReusableCell(using: progressRegistration, for: path, item: item)
            case .country(let code):
                view.dequeueConfiguredReusableCell(using: countryRegistration, for: path, item: code)
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SectionTitleSupplementaryView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, path in
            self?.configure(header, section: path.section)
        }
        dataSource.supplementaryViewProvider = { view, kind, path in
            view.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: path)
        }
        for name in [Notification.Name.countryAccessDidChange, .stakePackDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(accessChanged), name: name, object: nil)
        }
        installBalance()
        apply(animated: false)
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasShownFocus, focus == .boosts else { return }
        hasShownFocus = true
        flashStakePack()
    }

    /// Flashes the pack's row — Boosts lead the list, so it is already in
    /// view: selected without animation (the press wash), then let go with
    /// one — the system's way of saying "here" (Settings does the same for a
    /// deep link).
    func flashStakePack() {
        guard let path = dataSource.indexPath(for: .stakePack) else { return }
        collectionView.selectItem(at: path, animated: false, scrollPosition: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.collectionView.deselectItem(at: path, animated: true)
        }
    }

    // MARK: - Content

    /// The codes each section shows under the current search: Unlocked with
    /// the home country first, then by rank; Locked by rank.
    func rows() -> (unlocked: [String], locked: [String]) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var unlocked: [String] = []
        var locked: [String] = []
        for standing in access.standings().sorted(by: { $0.rank < $1.rank }) {
            if !needle.isEmpty {
                let name = atlas.country(code: standing.code)?.name ?? ""
                guard name.localizedStandardContains(needle)
                    || standing.code.caseInsensitiveCompare(needle) == .orderedSame else { continue }
            }
            if access.isUnlocked(standing.code) {
                unlocked.append(standing.code)
            } else {
                locked.append(standing.code)
            }
        }
        // Home first, then where the device is.
        for code in [access.currentCountry, access.homeCountry].compactMap({ $0 }) {
            if let index = unlocked.firstIndex(of: code) {
                unlocked.insert(unlocked.remove(at: index), at: 0)
            }
        }
        return (unlocked, locked)
    }

    private func apply(animated: Bool) {
        let rows = rows()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if showsBoosts {
            snapshot.appendSections([.boosts])
            snapshot.appendItems([.stakePack], toSection: .boosts)
        }
        snapshot.appendSections([.progress])
        snapshot.appendItems([.progress], toSection: .progress)
        if !rows.unlocked.isEmpty {
            snapshot.appendSections([.unlocked])
            snapshot.appendItems(rows.unlocked.map(Item.country), toSection: .unlocked)
        }
        if !rows.locked.isEmpty {
            snapshot.appendSections([.locked])
            snapshot.appendItems(rows.locked.map(Item.country), toSection: .locked)
        }
        // Every row still shown re-reads: the balance changes which prices are
        // in reach, an unlock what a row ends with. (Only rows already there —
        // an inserted row is fresh. The progress block and the headers are
        // updated in place below, so that the bar can animate.)
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { $0 != .progress && shown.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: animated)
        refreshInPlace(animated: animated)
        updateEmptyState(isEmpty: rows.unlocked.isEmpty && rows.locked.isEmpty)
    }

    /// The progress block and the section headers, where they are on screen:
    /// neither is reconfigured by the snapshot — a header is not an item, and
    /// the bar only animates outside the data source's apply.
    private func refreshInPlace(animated: Bool) {
        if let path = dataSource.indexPath(for: .progress),
           let cell = collectionView.cellForItem(at: path) as? CountryShopProgressCell {
            let (owned, total) = ownedAndTotal()
            cell.configure(owned: owned, total: total, animated: animated && view.window != nil)
        }
        let kind = UICollectionView.elementKindSectionHeader
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: path)
                as? SectionTitleSupplementaryView else { continue }
            configure(header, section: path.section)
        }
    }

    /// Boosts shows with a seller, and outside a search (a search of countries).
    var showsBoosts: Bool {
        stakePacks != nil && query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func updateEmptyState(isEmpty: Bool) {
        // Only a search can empty the list: the home country is always unlocked.
        contentUnavailableConfiguration = isEmpty && !query.isEmpty ? UIContentUnavailableConfiguration.search() : nil
    }

    private func ownedAndTotal() -> (owned: Int, total: Int) {
        let standings = access.standings()
        return (standings.filter { access.isUnlocked($0.code) }.count, standings.count)
    }

    /// "Unlocked 3" / "Locked 234" — the count in the secondary colour: the
    /// rows the section SHOWS, so a search's count is its results'.
    func headerContent(for section: Section) -> SectionTitleView.Content? {
        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(section) else { return nil }
        let count = snapshot.numberOfItems(inSection: section)
        let title: String
        switch section {
        case .progress: return nil
        case .boosts: return SectionTitleView.Content(title: "Boosts")
        case .unlocked: title = "Unlocked"
        case .locked: title = "Locked"
        }
        return SectionTitleView.Content(
            title: title, count: count.formatted(),
            countAccessibilityValue: count == 1 ? "1 country" : "\(count.formatted()) countries"
        )
    }

    private func configure(_ header: SectionTitleSupplementaryView, section index: Int) {
        guard let section = dataSource.sectionIdentifier(for: index),
              let content = headerContent(for: section) else { return }
        header.configure(content)
    }

    private func configure(_ cell: CountryShopRowCell, code: String) {
        guard let country = atlas.country(code: code), let standing = access.standing(of: code) else { return }
        cell.configure(
            flag: flag(for: country), name: country.name, rank: standing.rank,
            likes: CountryStanding.compact(standing.likes),
            posts: CountryStanding.compact(Int64(standing.posts))
        )

        let accessory: UICellAccessory
        let unlocked = access.isUnlocked(code)
        if unlocked {
            priceButtons[code] = nil
            let label = UILabel()
            label.font = .appFont(forTextStyle: .subheadline)
            if code == access.homeCountry {
                label.text = "Home"
                label.textColor = .secondaryLabel
            } else if code == access.currentCountry {
                // Open because the device is there, for as long as it is.
                label.text = "You're here"
                label.textColor = .secondaryLabel
            } else {
                let text = NSMutableAttributedString(attachment: NSTextAttachment(
                    image: UIImage(systemName: "checkmark.circle.fill")!
                        .withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
                ))
                text.append(NSAttributedString(string: " Unlocked"))
                label.attributedText = text
                label.textColor = .secondaryLabel
            }
            label.sizeToFit()
            accessory = .customView(configuration: .init(
                customView: label, placement: .trailing(), reservedLayoutWidth: .actual
            ))
        } else {
            let button = priceButton(for: country, price: standing.price)
            priceButtons[code] = button
            accessory = button.cellAccessory()
        }
        // A country unlocked while its row is on screen: the price fades into
        // "Unlocked" rather than being cut over (#935).
        let unlocks = shownUnlocked[code] == false && unlocked && cell.window != nil
        shownUnlocked[code] = unlocked
        if unlocks {
            UIView.transition(with: cell, duration: AppButton.Metrics.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                cell.accessories = [accessory]
            }
        } else {
            cell.accessories = [accessory]
        }
        cell.accessibilityLabel = "\(country.name), rank \(standing.rank), \(standing.likes) likes"
            + (access.isUnlocked(code) ? ", unlocked" : ", \(standing.price) gems")
    }

    /// "◆ 50", the tap opening the offer. Out of reach it is the button's
    /// DISABLED state — greyed, a tap does nothing (owner, 2026-10-11, #935) —
    /// and it comes back the moment the balance covers it (the shop
    /// reconfigures its rows on every balance change).
    private func priceButton(for country: CountryAtlas.Country, price: Int) -> AppButton {
        let button = priceButton(price: price, accessibilityLabel: "Unlock \(country.name) for \(price) gems")
        button.isEnabled = access.gems >= price
        button.addAction(UIAction { [weak self] _ in self?.offer(country) }, for: .primaryActionTriggered)
        return button
    }

    /// A price on the app's button (#931): the tinted pill, a diamond and the
    /// price. As a list accessory it goes through `AppButton.cellAccessory`,
    /// whose measured host is what receives the taps (the hand-made host this
    /// replaced). With a `menu`, the tap raises it.
    private func priceButton(price: Int, accessibilityLabel: String, menu: UIMenu? = nil) -> AppButton {
        Self.priceButton(price: price, accessibilityLabel: accessibilityLabel, menu: menu)
    }

    static func priceButton(price: Int, accessibilityLabel: String, menu: UIMenu? = nil) -> AppButton {
        let button = AppButton(
            aspect: .pill(.tinted), size: .row,
            content: AppButton.Content(title: price.formatted(), symbol: "diamond.fill")
        )
        button.accessibilityLabel = accessibilityLabel
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
        return button
    }

    /// The price buttons on screen, by country — for the tests.
    private var priceButtons: [String: AppButton] = [:]
    /// Whether each row was last drawn unlocked: an unlock on screen fades.
    private var shownUnlocked: [String: Bool] = [:]
    /// The pack's price button, while it shows one — for the tests.
    private(set) weak var debugPackPriceButton: AppButton?

    /// A locked country's price button. Internal for tests.
    func debugPriceButton(for code: String) -> AppButton? { priceButtons[code] }

    // MARK: - Boosts

    /// The pack's row: what it is, then its price — or, while a pack is
    /// loaded, "Active — N left" in place of one (packs don't stack).
    private func configure(_ cell: StakePackRowCell) {
        guard let stakePacks else { return }
        let offer = stakePacks.offer
        cell.configure(offer)
        if offer.isActive {
            let label = UILabel()
            label.font = .appFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.text = Self.activeText(offer)
            label.sizeToFit()
            cell.accessories = [.customView(configuration: .init(
                customView: label, placement: .trailing(), reservedLayoutWidth: .actual
            ))]
        } else {
            let button = packPriceButton(offer)
            debugPackPriceButton = button
            cell.accessories = [button.cellAccessory()]
        }
        cell.accessibilityLabel = "\(StakePackRowCell.title(offer)), \(StakePackRowCell.detail(offer))"
        cell.accessibilityValue = offer.isActive ? Self.activeText(offer) : "\(offer.price) gems"
    }

    /// "Active — 7 left".
    static func activeText(_ offer: StakePackOffer) -> String { "Active — \(offer.shotsLeft) left" }

    /// "◆ 20", as a country's price — and the same rule: out of reach it is
    /// disabled (#935). In reach, the tap raises a one-line confirmation: the
    /// pack is bought on the spot, so the gems never go on a stray touch. An
    /// account that may not buy (a teen, #803) keeps the button and reads why
    /// in the menu.
    private func packPriceButton(_ offer: StakePackOffer) -> AppButton {
        Self.packPriceButton(offer, access: access) { [weak self] in
            guard let self else { return }
            MemberGates.perform(.shop, from: self) { [weak self] in self?.buyStakePack() }
        }
    }

    /// The pack's price and its confirmation menu, for every screen that
    /// sells it (the list's row, the storefront's card, the pack's page).
    static func packPriceButton(
        _ offer: StakePackOffer, access: any CountryAccess, buy confirmed: @escaping @MainActor () -> Void
    ) -> AppButton {
        let gems = access.gems
        let buy = UIAction(
            title: "Buy for \(offer.price) gems",
            image: GemSymbol.glyphImage()
        ) { _ in confirmed() }
        if access.purchasesRestricted {
            buy.attributes = .disabled
            buy.subtitle = PurchaseRestriction.message
        } else if gems < offer.price {
            buy.attributes = .disabled
            buy.subtitle = "\(offer.price - gems) more gems needed"
        }
        let menu = UIMenu(
            title: "\(StakePackRowCell.title(offer)) — \(StakePackRowCell.detail(offer))", children: [buy]
        )
        let button = priceButton(
            price: offer.price,
            accessibilityLabel: "Buy \(StakePackRowCell.title(offer)) for \(offer.price) gems",
            menu: menu
        )
        button.isEnabled = access.purchasesRestricted || gems >= offer.price
        return button
    }

    /// Buys the pack from `presenter`, saying why a refusal refused.
    @discardableResult
    static func buyStakePack(
        _ offer: StakePackOffer? = nil,
        from stakePacks: any StakePackSelling, access: any CountryAccess, presenter: UIViewController
    ) -> StakePackPurchase? {
        guard !access.purchasesRestricted else { return nil }
        let outcome = offer.map { stakePacks.buyPack($0) } ?? stakePacks.buyPack()
        if let refusal = refusalMessage(for: outcome) {
            Feedback.failure(refusal, from: presenter)
        } else {
            HapticNotification().notificationOccurred(.success)
        }
        return outcome
    }

    /// Buys the pack. Internal for tests — the confirmation menu cannot be
    /// raised in one.
    @discardableResult
    func buyStakePack() -> StakePackPurchase? {
        // A refusal says WHY (#803): a vibration with no words reads as a
        // tap that missed; the failure toast carries the error haptic. Bought,
        // the row turns into "Active — N left" on the spot, so the hand only
        // needs to feel it.
        guard let stakePacks else { return nil }
        return Self.buyStakePack(from: stakePacks, access: access, presenter: self)
    }

    /// Why the store refused a pack, in the toast's words — nil when it was
    /// bought.
    static func refusalMessage(for outcome: StakePackPurchase) -> String? {
        switch outcome {
        case .bought:
            return nil
        case .packStillActive(let shotsLeft):
            return "Your pack is still active, \(shotsLeft) left"
        case .insufficientGems(let needed, let have):
            let missing = max(needed - have, 1)
            return missing == 1 ? "1 more gem needed" : "\(missing) more gems needed"
        }
    }

    private func flag(for country: CountryAtlas.Country) -> UIImage {
        if let image = flags[country.code] { return image }
        let image = Self.flagImage(for: country, pointSize: 28)
        flags[country.code] = image
        return image
    }

    /// A country's flag emoji drawn as an image of `pointSize`.
    static func flagImage(for country: CountryAtlas.Country, pointSize: CGFloat, trimmed: Bool = false) -> UIImage {
        let text = country.flag as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: pointSize)]
        let size = text.size(withAttributes: attributes)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }
        return trimmed ? trimmingTransparentEdges(of: image) : image
    }

    /// The image cropped to its drawn pixels: an emoji's glyph carries side
    /// bearings, which read as a gap too wide beside a name (owner, 2026-10-13).
    static func trimmingTransparentEdges(of image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = cgImage.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    /// The offer the map makes, over the shop.
    ///
    /// ⚠️ From the TOP of what the shop has presented: while the search field
    /// is active, the search controller is the shop's presented controller,
    /// and presenting from under it fails ("already presenting").
    private func offer(_ country: CountryAtlas.Country) {
        Self.offer(country, access: access, from: self)
    }

    /// The unlock sheet — a country's item page — over the top of what
    /// `host` presents.
    static func offer(_ country: CountryAtlas.Country, access: any CountryAccess, from host: UIViewController) {
        // The search keeps its results but lets the keyboard go: it would
        // stand over the offer's button.
        host.navigationItem.searchController?.searchBar.resignFirstResponder()
        var presenter: UIViewController = host.navigationController ?? host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        guard !((presenter as? UINavigationController)?.viewControllers.first is CountryUnlockSheetViewController)
        else { return }
        presenter.present(
            CountryUnlockSheetViewController(country: country, access: access).wrappedInSheet(), animated: true
        )
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The toolbar carries the search field; it leaves with this screen.
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    @objc private func accessChanged() {
        installBalance()
        apply(animated: true)
    }

    /// The gem balance on the bar's RIGHT: a cyan diamond and the count, in the
    /// glass the system draws behind any bar item.
    ///
    /// ⚠️ AN IMAGE VIEW, NOT A TEXT ATTACHMENT: bar items sit on glass, which
    /// draws a label's attachments vibrant — the diamond came out black.
    /// `.alwaysOriginal` (`GemSymbol.glyphImage`) for the same reason, the
    /// tint as the belt. And a FRESH item per change, with a stable
    /// identifier: a reused custom-view item keeps a wrapper sized for the
    /// old count.
    private func installBalance() {
        // Trailing, where a sheet had its close button: the back button
        // leads (owner, 2026-10-13).
        navigationItem.rightBarButtonItem = Self.balanceItem(gems: access.gems)
    }

    /// The gems balance as a bar item: a cyan diamond and the count.
    static func balanceItem(gems: Int) -> UIBarButtonItem {
        let diamond = UIImageView(image: GemSymbol.glyphImage(.init(pointSize: 14, weight: .bold)))
        diamond.tintColor = GemSymbol.tint
        let count = UILabel()
        count.text = gems.formatted()
        count.font = .scaledMonospacedDigitSystemFont(
            ofSize: 15, weight: .semibold, relativeTo: .subheadline, maximumPointSize: 20
        )
        count.textColor = .label
        let balance = UIStackView(arrangedSubviews: [diamond, count])
        balance.spacing = 6
        balance.alignment = .center
        balance.isLayoutMarginsRelativeArrangement = true
        balance.directionalLayoutMargins = .init(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)
        balance.isAccessibilityElement = true
        balance.accessibilityLabel = "\(gems) gems"
        let fitted = balance.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        balance.frame.size = CGSize(width: ceil(fitted.width), height: 36)
        let item = UIBarButtonItem(customView: balance)
        item.identifier = balanceItemIdentifier
        item.accessibilityLabel = "\(gems) gems"
        return item
    }

    /// The list's appearance — plain: rows the sheet's full width.
    static let listAppearance = UICollectionLayoutListConfiguration.Appearance.plain

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index) ?? .progress
            // PLAIN, not inset-grouped: full-width rows on the standard
            // margins (see the type's note).
            var configuration = UICollectionLayoutListConfiguration(appearance: Self.listAppearance)
            configuration.backgroundColor = .clear
            configuration.headerMode = section == .progress ? .none : .supplementary
            // The progress block is a heading of the page, not a row.
            configuration.showsSeparators = section != .progress
            let layout = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // A plain list pins its headers; these scroll with their rows.
            // "Unlocked" and "Locked" are landmarks in one list, and pinned on
            // a clear background they would sit over the rows passing under.
            for header in layout.boundarySupplementaryItems {
                header.pinToVisibleBounds = false
            }
            if section == .progress {
                // The block sits on the page, just under the search field (or
                // a section's breath under Boosts); the first header's own
                // top padding is the gap below it.
                layout.contentInsets.top = self?.showsBoosts == true ? Spacing.lg : Spacing.xs
                layout.contentInsets.bottom = 0
            }
            return layout
        }
    }
}

extension CountryShopViewController: UICollectionViewDelegate {
    /// Opened from the map, a row goes to its country (a locked one then
    /// makes its offer there, lifted). Opened from the wallet, a locked row
    /// makes its offer here, and an unlocked one has nothing more to say.
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .country(let code) = dataSource.itemIdentifier(for: indexPath),
              let country = atlas.country(code: code) else { return }
        if let onShowCountry {
            onShowCountry(code)
        } else if !access.isUnlocked(code) {
            offer(country)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        // The pack's row is bought through its price, not by a tap on the row.
        guard case .country(let code) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return onShowCountry != nil || !access.isUnlocked(code)
    }
}

extension CountryShopViewController: UISearchResultsUpdating, UISearchControllerDelegate {
    public func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        apply(animated: false)
    }

}

/// A country's row: flag, name, and "#rank · ♥ likes · posts" under it; the
/// trailing price / Unlocked / Home is the cell's accessory.
///
/// ⚠️ THE HEART IS AN IMAGE VIEW, NOT A TEXT ATTACHMENT. At the medium detent
/// the sheet is glass, and glass draws a label's attachments vibrant: the red
/// heart of a list configuration's secondary text came out grey there (and
/// red again at large, once the sheet turns opaque). An image view keeps its
/// colour, like the flags and the price capsules beside it.
final class CountryShopRowCell: UICollectionViewListCell {
    private let flagView = UIImageView()
    let nameLabel = UILabel()
    private let rankLabel = UILabel()
    let heartView = UIImageView(image: UIImage(systemName: "heart.fill")?
        .applyingSymbolConfiguration(.init(pointSize: 10, weight: .bold))?
        .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
    private let statsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        flagView.contentMode = .center
        nameLabel.font = .appFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        let detailFont = UIFont.scaledMonospacedDigitSystemFont(
            ofSize: UIFont.defaultPointSize(for: .footnote), relativeTo: .footnote
        )
        for label in [rankLabel, statsLabel] {
            label.font = detailFont
            label.textColor = .secondaryLabel
        }
        heartView.tintColor = PointsSymbol.tint
        heartView.setContentHuggingPriority(.required, for: .horizontal)
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        let details = UIStackView(arrangedSubviews: [rankLabel, heartView, statsLabel])
        details.alignment = .center
        details.spacing = 3
        let column = UIStackView(arrangedSubviews: [nameLabel, details])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 3
        let row = UIStackView(arrangedSubviews: [flagView, column])
        row.alignment = .center
        row.spacing = Spacing.lg
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            flagView.widthAnchor.constraint(equalToConstant: 34),
            flagView.heightAnchor.constraint(equalToConstant: 34),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            // The separator starts under the name, as a list configuration's does.
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// No resting ground: the row lies on the sheet, whose glass (collapsed)
    /// or opaque ground (full) runs behind the whole list. A plain list cell's
    /// default background is opaque and painted white bands over the glass.
    /// A press draws the list's full-width wash.
    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = state.isHighlighted || state.isSelected ? .systemFill : .clear
        backgroundConfiguration = background
    }

    func configure(flag: UIImage, name: String, rank: Int, likes: String, posts: String) {
        flagView.image = flag
        nameLabel.text = name
        rankLabel.text = "#\(rank)  ·  "
        statsLabel.text = "\(likes)  ·  \(posts) posts"
    }
}

/// The list's first item: "Your map", how many countries are unlocked, and
/// the bar. On the page, not a card.
final class CountryShopProgressCell: UICollectionViewListCell {
    private let summaryLabel = UILabel()
    private let countLabel = UILabel()
    let progressView = UIProgressView(progressViewStyle: .default)

    var countText: String? { countLabel.text }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        summaryLabel.text = "Your map"
        summaryLabel.font = .appFont(forTextStyle: .headline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        countLabel.font = .appFont(forTextStyle: .subheadline)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .right
        progressView.progressTintColor = .systemBlue

        let summaryRow = UIStackView(arrangedSubviews: [summaryLabel, countLabel])
        summaryRow.spacing = Spacing.sm
        let stack = UIStackView(arrangedSubviews: [summaryRow, progressView])
        stack.axis = .vertical
        stack.spacing = Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(owned: Int, total: Int, animated: Bool) {
        countLabel.text = "\(owned) of \(total) countries"
        progressView.setProgress(total == 0 ? 0 : Float(owned) / Float(total), animated: animated)
        accessibilityLabel = "Your map, \(owned) of \(total) countries unlocked"
    }
}

/// Boosts' one row: the pack's badge, "×100 cartridges", and what it holds
/// under it; the trailing price / "Active — N left" is the cell's accessory.
/// Shaped like a country's row (34pt leading visual, name over details) so
/// the two sections read as one list.
final class StakePackRowCell: UICollectionViewListCell {
    private let badge = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()

    /// "×100 cartridges".
    static func title(_ offer: StakePackOffer) -> String {
        "\(StakeMenu.shotName(offer.pointsPerShot)) cartridges"
    }

    /// "10 shots · 10 points a tap" — the pack's whole promise.
    static func detail(_ offer: StakePackOffer) -> String {
        "\(offer.shotsPerPack) shots · \(StakeMenu.points(offer.pointsPerShot)) a tap"
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The points' red disc with a white bolt — the shot is a STAKE of
        // points, so it wears their colour (`PointsSymbol`), not the gems'.
        badge.image = UIImage(systemName: StakeMenu.shotGlyph)?
            .applyingSymbolConfiguration(.init(pointSize: 15, weight: .bold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        badge.contentMode = .center
        badge.backgroundColor = PointsSymbol.tint
        badge.layer.cornerRadius = 17
        badge.layer.cornerCurve = .circular
        titleLabel.font = .appFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .appFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel

        let column = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 3
        let row = UIStackView(arrangedSubviews: [badge, column])
        row.alignment = .center
        row.spacing = Spacing.lg
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 34),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// No resting ground, as a country's row: the sheet's own runs behind.
    /// Never pressed (the pack is bought through its price), but SELECTED
    /// by the Shop's Boosts focus, which draws the list's wash to flash it.
    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = state.isSelected ? .systemFill : .clear
        backgroundConfiguration = background
    }

    func configure(_ offer: StakePackOffer) {
        titleLabel.text = Self.title(offer)
        detailLabel.text = Self.detail(offer)
    }
}
