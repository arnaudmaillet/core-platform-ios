import DesignSystem
import UIKit

/// Every country, and unlocking them: the shop behind the map's globe button
/// and the wallet's Countries row.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ Countries                     ◆ 100  │
///  │ 🔍 Search                            │
///  │ Your map        3 of 237 countries   │
///  │ ▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
///  │ [   Locked   |   Yours   ]           │
///  │ 🇺🇸 United States                     │
///  │    #1 · ♥ 38.2K · 1.2K posts  [◆ 50] │
///  │ 🇪🇸 Spain                             │
///  │    #4 · ♥ 12.4K · 86 posts    [◆ 50] │
///  └──────────────────────────────────────┘
/// ```
///
/// Busiest first, the rank being what prices a country
/// (`CountryStanding.price(forRank:)`). A price opens the same offer the map
/// makes (`CountryUnlockSheetViewController`), so buying reads the same from
/// both doors. Opened from the map, a row also takes you TO the country
/// (`onShowCountry`); opened from the wallet, there is no map to show it on.
public final class CountryShopViewController: UIViewController {
    /// Shows a country on the map. Nil hides the "show" half of a row's tap.
    public var onShowCountry: ((String) -> Void)?

    private enum Segment: Int { case locked, owned }
    private enum Section { case main }

    private let access: any CountryAccess
    private let atlas: CountryAtlas
    private let summaryLabel = UILabel()
    private let countLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let segments = UISegmentedControl(items: ["Locked", "Yours"])
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var query = ""
    private var flags: [String: UIImage] = [:]

    public init(access: any CountryAccess, atlas: CountryAtlas = .shared) {
        self.access = access
        self.atlas = atlas
        super.init(nibName: nil, bundle: nil)
        title = "Countries"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shop in its own navigation stack, as a large sheet.
    public static func sheet(
        access: any CountryAccess, onShowCountry: ((String) -> Void)? = nil
    ) -> UIViewController {
        let shop = CountryShopViewController(access: access)
        shop.onShowCountry = onShowCountry
        let navigation = UINavigationController(rootViewController: shop)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search countries"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked

        summaryLabel.text = "Your map"
        summaryLabel.font = .preferredFont(forTextStyle: .headline)
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .right
        progress.progressTintColor = .systemBlue
        segments.selectedSegmentIndex = Segment.locked.rawValue
        segments.addAction(UIAction { [weak self] _ in self?.apply(animated: false) }, for: .valueChanged)

        let summaryRow = UIStackView(arrangedSubviews: [summaryLabel, countLabel])
        let header = UIStackView(arrangedSubviews: [summaryRow, progress, segments])
        header.axis = .vertical
        header.spacing = Spacing.sm
        header.setCustomSpacing(Spacing.md, after: progress)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm),
            header.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.xs),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, code in self?.configure(cell, code: code)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, code in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: code)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessChanged), name: .countryAccessDidChange, object: nil
        )
        refreshHeader()
        apply(animated: false)
    }

    // MARK: - Content

    /// The codes the current segment and search show, busiest first — the
    /// home country leading "Yours".
    private func visibleCodes() -> [String] {
        let wantsOwned = segments.selectedSegmentIndex == Segment.owned.rawValue
        let needle = query.trimmingCharacters(in: .whitespaces)
        var codes = access.standings().filter { standing in
            guard access.isUnlocked(standing.code) == wantsOwned else { return false }
            guard !needle.isEmpty else { return true }
            let name = atlas.country(code: standing.code)?.name ?? ""
            return name.localizedStandardContains(needle) || standing.code.caseInsensitiveCompare(needle) == .orderedSame
        }.map(\.code)
        if wantsOwned, let home = codes.firstIndex(of: access.homeCountry) {
            codes.insert(codes.remove(at: home), at: 0)
        }
        return codes
    }

    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(visibleCodes())
        // Every row still shown re-reads: the balance changes which prices are
        // in reach. (Only rows already there — an inserted row is fresh.)
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: animated)
        updateEmptyState(isEmpty: snapshot.itemIdentifiers.isEmpty)
    }

    private func updateEmptyState(isEmpty: Bool) {
        guard isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var empty = UIContentUnavailableConfiguration.empty()
        if !query.isEmpty {
            empty = .search()
        } else {
            empty.image = UIImage(systemName: "globe.europe.africa.fill")
            empty.text = "The whole world is yours"
            empty.secondaryText = "Every country is unlocked on your map."
        }
        contentUnavailableConfiguration = empty
    }

    private func refreshHeader() {
        let total = access.standings().count
        let owned = access.standings().filter { access.isUnlocked($0.code) }.count
        countLabel.text = "\(owned) of \(total) countries"
        progress.setProgress(total == 0 ? 0 : Float(owned) / Float(total), animated: view.window != nil)
        segments.setTitle("Locked · \(total - owned)", forSegmentAt: Segment.locked.rawValue)
        segments.setTitle("Yours · \(owned)", forSegmentAt: Segment.owned.rawValue)
        installBalance()
    }

    private func configure(_ cell: UICollectionViewListCell, code: String) {
        guard let country = atlas.country(code: code), let standing = access.standing(of: code) else { return }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = country.name
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.image = flag(for: country)
        content.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
        let details = NSMutableAttributedString(string: "#\(standing.rank)  ·  ")
        details.append(NSAttributedString(attachment: NSTextAttachment(
            image: UIImage(systemName: "heart.fill")!
                .applyingSymbolConfiguration(.init(pointSize: 10, weight: .bold))!
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        )))
        details.append(NSAttributedString(
            string: " \(LockedCountryAnnotationView.compact(standing.likes))  ·  "
                + "\(LockedCountryAnnotationView.compact(Int64(standing.posts))) posts"
        ))
        content.secondaryAttributedText = details
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular
        )
        content.textToSecondaryTextVerticalPadding = 3
        cell.contentConfiguration = content

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
    private func offer(_ country: CountryAtlas.Country) {
        guard presentedViewController == nil else { return }
        present(CountryUnlockSheetViewController(country: country, access: access), animated: true)
    }

    @objc private func accessChanged() {
        refreshHeader()
        apply(animated: true)
    }

    /// The gem balance in the bar: a cyan diamond and the count.
    ///
    /// ⚠️ AN IMAGE VIEW, NOT A TEXT ATTACHMENT: bar items sit on glass, which
    /// draws a label's attachments vibrant — the diamond came out black. And
    /// a FRESH item per change, with a stable identifier: a reused custom-view
    /// item keeps a wrapper sized for the old count.
    private func installBalance() {
        let diamond = UIImageView(image: UIImage(systemName: "diamond.fill")?
            .applyingSymbolConfiguration(.init(pointSize: 13, weight: .bold)))
        diamond.tintColor = GemSymbol.tint
        let count = UILabel()
        count.text = "\(access.gems)"
        count.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        let balance = UIStackView(arrangedSubviews: [diamond, count])
        balance.spacing = 5
        balance.alignment = .center
        balance.isAccessibilityElement = true
        balance.accessibilityLabel = "\(access.gems) gems"
        balance.frame.size = balance.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let item = UIBarButtonItem(customView: balance)
        item.identifier = "countries.balance"
        item.sharesBackground = false
        item.hidesSharedBackground = true
        navigationItem.rightBarButtonItem = item
    }

    private static func layout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .clear
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }
}

extension CountryShopViewController: UICollectionViewDelegate {
    /// Opened from the map, a row goes to its country (a locked one then
    /// makes its offer there, lifted). Opened from the wallet, a locked row
    /// makes its offer here, and an unlocked one has nothing more to say.
    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let code = dataSource.itemIdentifier(for: indexPath),
              let country = atlas.country(code: code) else { return }
        if let onShowCountry {
            onShowCountry(code)
        } else if !access.isUnlocked(code) {
            offer(country)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard let code = dataSource.itemIdentifier(for: indexPath) else { return false }
        return onShowCountry != nil || !access.isUnlocked(code)
    }
}

extension CountryShopViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        apply(animated: false)
    }
}
