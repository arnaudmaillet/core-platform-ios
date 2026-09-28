import DesignSystem
import MapsInterface
import UIKit

/// Every country, and unlocking them: the Shop behind the Explore header's
/// storefront and the wallet's Countries card.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │               ▔▔                     │
///  │ (◆ 100)        Shop             (✕)  │
///  │ 🔍 Search countries                  │
///  │ Your map        3 of 237 countries   │  ← scrolls with the list
///  │ ▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
///  │ UNLOCKED · 3                         │
///  │ 🇫🇷 France                     Home   │
///  │ 🇺🇸 United States          ✓ Unlocked │
///  │ LOCKED · 234                         │
///  │ 🇪🇸 Spain                             │
///  │    #4 · ♥ 12.4K · 86 posts    [◆ 50] │
///  └──────────────────────────────────────┘
/// ```
///
/// # One list, two sections
/// The progress block leads the collection — it is an ITEM, so it scrolls
/// away with the rows rather than standing over them. Then **Unlocked** (the
/// home country first, then by rank) and **Locked** (by rank), each header
/// carrying its count. Search filters both sections at once; a section left
/// empty by it is dropped, and nothing left at all is the system's search
/// empty state. An unlock moves its row from Locked to Unlocked, animated.
///
/// The rank is what prices a country (`CountryStanding.price(forRank:)`). A
/// price opens the same offer the map makes (`CountryUnlockSheetViewController`),
/// so buying reads the same from both doors. Opened from the map, a row also
/// takes you TO the country (`onShowCountry`); opened from the wallet, there
/// is no map to show it on.
///
/// # Bare chrome over the list
/// The collection view is the sheet's whole content, edge to edge; the bar —
/// gems on the left, the title, the close button on the right — and the
/// search field float over it with NO material behind them, the app's rule
/// for every header (`prefersClearTopEdge`). The bar items are plain bar
/// items, so the system draws their glass.
///
/// # Collapsed, then full
/// The sheet opens at `.medium()` — the progress block and the first rows —
/// and grows to `.large()` by a drag or by scrolling the list up
/// (`prefersScrollingExpandsWhenScrolledToEdge`). A system detent, not a
/// measured one: the list is long and the cut row is the cue to scroll, so
/// there is nothing to measure. Searching grows it to large, where the
/// keyboard leaves room for results.
public final class CountryShopViewController: UIViewController {
    /// Shows a country on the map. Nil hides the "show" half of a row's tap.
    public var onShowCountry: ((String) -> Void)?

    enum Section: Hashable { case progress, unlocked, locked }
    enum Item: Hashable {
        /// "Your map · N of 237", the first item of the list.
        case progress
        case country(String)
    }

    /// Stable identifiers for the bar items: a reused identifier is how
    /// iOS 26 matches an item across a reinstall.
    static let balanceItemIdentifier = "shop.balance"
    static let closeItemIdentifier = "shop.close"

    private let access: any CountryAccess
    private let atlas: CountryAtlas
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var query = ""
    private var flags: [String: UIImage] = [:]

    public init(access: any CountryAccess, atlas: CountryAtlas = .shared) {
        self.access = access
        self.atlas = atlas
        super.init(nibName: nil, bundle: nil)
        title = CountryShopEntry.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shop in its own navigation stack, as a sheet that opens collapsed
    /// and drags to full height (see the type's note).
    public static func sheet(
        access: any CountryAccess, onShowCountry: ((String) -> Void)? = nil
    ) -> UIViewController {
        let shop = CountryShopViewController(access: access)
        shop.onShowCountry = onShowCountry
        let navigation = UINavigationController(rootViewController: shop)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        return navigation
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ CLEAR: the sheet's own ground is the surface — glass while
        // collapsed, opaque once full height — exactly as the wallet sheet.
        // A grouped colour here sat over the glass and defeated it (the
        // collapsed Shop was a flat grey slab, 2026-09-28).
        view.backgroundColor = .clear
        navigationItem.largeTitleDisplayMode = .never

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search countries"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        // Left automatic, iOS 26 hands an iPhone sheet the bottom-aligned
        // search bar; `.stacked` keeps it under the title.
        navigationItem.preferredSearchBarPlacement = .stacked

        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        close.identifier = Self.closeItemIdentifier
        navigationItem.rightBarButtonItem = close

        // The whole sheet: the bar and the search field float over it.
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        // No effect under the bar: the rows run up under the pills untouched
        // — see `prefersClearTopEdge`.
        collectionView.prefersClearTopEdge()
        view.addSubview(collectionView)
        collectionView.pin(to: view)

        let progressRegistration = UICollectionView.CellRegistration<CountryShopProgressCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            let (owned, total) = ownedAndTotal()
            cell.configure(owned: owned, total: total, animated: false)
        }
        let countryRegistration = UICollectionView.CellRegistration<CountryShopRowCell, String> {
            [weak self] cell, _, code in self?.configure(cell, code: code)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            switch item {
            case .progress:
                view.dequeueConfiguredReusableCell(using: progressRegistration, for: path, item: item)
            case .country(let code):
                view.dequeueConfiguredReusableCell(using: countryRegistration, for: path, item: code)
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, path in
            self?.configure(header, section: path.section)
        }
        dataSource.supplementaryViewProvider = { view, kind, path in
            view.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: path)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessChanged), name: .countryAccessDidChange, object: nil
        )
        installBalance()
        apply(animated: false)
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
        if let home = unlocked.firstIndex(of: access.homeCountry) {
            unlocked.insert(unlocked.remove(at: home), at: 0)
        }
        return (unlocked, locked)
    }

    private func apply(animated: Bool) {
        let rows = rows()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
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
                as? UICollectionViewListCell else { continue }
            configure(header, section: path.section)
        }
    }

    private func updateEmptyState(isEmpty: Bool) {
        // Only a search can empty the list: the home country is always unlocked.
        contentUnavailableConfiguration = isEmpty && !query.isEmpty ? UIContentUnavailableConfiguration.search() : nil
    }

    private func ownedAndTotal() -> (owned: Int, total: Int) {
        let standings = access.standings()
        return (standings.filter { access.isUnlocked($0.code) }.count, standings.count)
    }

    /// "Unlocked · 3" / "Locked · 234": the rows the section SHOWS, so a
    /// search's count is its results'.
    func headerTitle(for section: Section) -> String? {
        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(section) else { return nil }
        let count = snapshot.numberOfItems(inSection: section)
        switch section {
        case .progress: return nil
        case .unlocked: return "Unlocked · \(count)"
        case .locked: return "Locked · \(count)"
        }
    }

    private func configure(_ header: UICollectionViewListCell, section index: Int) {
        guard let section = dataSource.sectionIdentifier(for: index) else { return }
        var content = header.defaultContentConfiguration()
        content.text = headerTitle(for: section)
        header.contentConfiguration = content
    }

    private func configure(_ cell: CountryShopRowCell, code: String) {
        guard let country = atlas.country(code: code), let standing = access.standing(of: code) else { return }
        cell.configure(
            flag: flag(for: country), name: country.name, rank: standing.rank,
            likes: LockedCountryAnnotationView.compact(standing.likes),
            posts: LockedCountryAnnotationView.compact(Int64(standing.posts))
        )

        let trailing: UIView
        if access.isUnlocked(code) {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .subheadline)
            if code == access.homeCountry {
                label.text = "Home"
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
            trailing = label
        } else {
            trailing = priceButton(for: country, price: standing.price)
        }
        trailing.sizeToFit()
        cell.accessories = [.customView(configuration: .init(
            customView: trailing, placement: .trailing(), reservedLayoutWidth: .actual
        ))]
        cell.accessibilityLabel = "\(country.name), rank \(standing.rank), \(standing.likes) likes"
            + (access.isUnlocked(code) ? ", unlocked" : ", \(standing.price) gems")
    }

    /// "◆ 50": blue in reach, grey out of it — tapping either opens the offer,
    /// which says how many gems are missing.
    private func priceButton(for country: CountryAtlas.Country, price: Int) -> UIView {
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "diamond.fill")?
            .applyingSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        configuration.imagePadding = 4
        configuration.title = "\(price)"
        configuration.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        configuration.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.tintColor = access.gems >= price ? .systemBlue : .systemGray
        button.accessibilityLabel = "Unlock \(country.name) for \(price) gems"
        button.addAction(UIAction { [weak self] _ in self?.offer(country) }, for: .primaryActionTriggered)
        // A bare button as a list accessory never gets its taps (the cell's
        // selection eats them): a sized host is what receives them.
        let host = UIView()
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        let size = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        host.frame = CGRect(origin: .zero, size: size)
        button.pin(to: host)
        return host
    }

    private func flag(for country: CountryAtlas.Country) -> UIImage {
        if let image = flags[country.code] { return image }
        let text = country.flag as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28)]
        let size = text.size(withAttributes: attributes)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }
        flags[country.code] = image
        return image
    }

    /// The offer the map makes, over the shop.
    ///
    /// ⚠️ From the TOP of what the shop has presented: while the search field
    /// is active, the search controller is the shop's presented controller,
    /// and presenting from under it fails ("already presenting").
    private func offer(_ country: CountryAtlas.Country) {
        // The search keeps its results but lets the keyboard go: it would
        // stand over the offer's button.
        navigationItem.searchController?.searchBar.resignFirstResponder()
        var presenter: UIViewController = navigationController ?? self
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        guard !(presenter is CountryUnlockSheetViewController) else { return }
        presenter.present(CountryUnlockSheetViewController(country: country, access: access), animated: true)
    }

    /// The close button. From the PRESENTER: on the shop itself `dismiss`
    /// would take down only an active search.
    private func close() {
        if let presenter = navigationController?.presentingViewController {
            presenter.dismiss(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func accessChanged() {
        installBalance()
        apply(animated: true)
    }

    /// The gem balance on the bar's LEFT: a cyan diamond and the count, in the
    /// glass the system draws behind any bar item.
    ///
    /// ⚠️ AN IMAGE VIEW, NOT A TEXT ATTACHMENT: bar items sit on glass, which
    /// draws a label's attachments vibrant — the diamond came out black.
    /// `.alwaysOriginal` (`GemSymbol.glyphImage`) for the same reason, the
    /// tint as the belt. And a FRESH item per change, with a stable
    /// identifier: a reused custom-view item keeps a wrapper sized for the
    /// old count.
    private func installBalance() {
        let diamond = UIImageView(image: GemSymbol.glyphImage(.init(pointSize: 14, weight: .bold)))
        diamond.tintColor = GemSymbol.tint
        let count = UILabel()
        count.text = access.gems.formatted()
        count.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        count.textColor = .label
        let balance = UIStackView(arrangedSubviews: [diamond, count])
        balance.spacing = 6
        balance.alignment = .center
        balance.isLayoutMarginsRelativeArrangement = true
        balance.directionalLayoutMargins = .init(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm)
        balance.isAccessibilityElement = true
        balance.accessibilityLabel = "\(access.gems) gems"
        let fitted = balance.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        balance.frame.size = CGSize(width: ceil(fitted.width), height: 36)
        let item = UIBarButtonItem(customView: balance)
        item.identifier = Self.balanceItemIdentifier
        item.accessibilityLabel = "\(access.gems) gems"
        navigationItem.leftBarButtonItem = item
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section = self?.dataSource?.sectionIdentifier(for: index) ?? .progress
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .clear
            configuration.headerMode = section == .progress ? .none : .supplementary
            let layout = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            if section == .progress {
                // The block sits on the page, just under the search field; the
                // first header's own top padding is the gap below it.
                layout.contentInsets.top = Spacing.xs
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

    /// Searching grows the sheet to full height: at medium, the keyboard
    /// would leave the results a strip.
    public func willPresentSearchController(_ searchController: UISearchController) {
        guard let sheet = navigationController?.sheetPresentationController,
              sheet.selectedDetentIdentifier != .large else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
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
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        let detailFont = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular
        )
        for label in [rankLabel, statsLabel] {
            label.font = detailFont
            label.textColor = .secondaryLabel
        }
        heartView.tintColor = .systemRed
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
        summaryLabel.font = .preferredFont(forTextStyle: .headline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
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
