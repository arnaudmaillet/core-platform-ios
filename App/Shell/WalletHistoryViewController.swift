import CoreNetworking
import CoreStorage
import DesignSystem
import PostGrid
import UIKit

/// The wallet's history (#400), from the server (wallet.v1
/// `ListWalletTransactions`) — every claim, stake, gift and purchase, newest
/// first, page by page, for both currencies or one, grouped by day (#1478).
/// Settings → Wallet and Purchases opens it, and so does the wallet hub's
/// Activity.
///
/// Nothing is sold for real money (the backend's decision of 2026-10-08), so
/// there is no Restore Purchases and no spending limit: the page is the
/// ledger, and a kind this build does not know is shown plainly rather than
/// hidden.
@MainActor
final class WalletHistoryViewController: UIViewController {
    enum Filter: Int, CaseIterable {
        case all, likes, gems

        var title: String {
            switch self {
            case .all: "All"
            case .likes: "Likes"
            case .gems: GemSymbol.name
            }
        }

        var currency: WalletTransaction.Currency? {
            switch self {
            case .all: nil
            case .likes: .likes
            case .gems: .gems
            }
        }
    }

    /// The list's sections: the filter, one per day of movements (the
    /// viewer's calendar), the undated ones, and the status rows.
    private nonisolated enum Section: Hashable {
        case filter
        case day(Date)
        case undated
        case status
    }

    private nonisolated enum Item: Hashable {
        case filter
        case transaction(WalletTransaction)
        case loading
        case failed
        case empty
        case loadingMore
    }

    private let wallet: WalletStore
    private var filter: Filter = .all
    private var transactions: [WalletTransaction] = []
    private var nextPageToken: String?
    private var phase: Phase = .loading
    private var failure: NetworkFailure?
    /// The page on its way, and which filter asked for it: a page for a
    /// filter the viewer left lands nowhere.
    private var pageLoad: Task<Void, Never>?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private enum Phase { case loading, loaded, failed }

    init(wallet: WalletStore) {
        self.wallet = wallet
        super.init(nibName: nil, bundle: nil)
        title = "Wallet and Purchases"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        reload()
    }

    // MARK: Loading

    private func reload() {
        pageLoad?.cancel()
        transactions = []
        nextPageToken = nil
        phase = .loading
        applySnapshot()
        loadPage(after: nil)
    }

    private func loadPage(after token: String?) {
        let asked = filter
        pageLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await wallet.transactions(currency: asked.currency, after: token)
                guard !Task.isCancelled, asked == filter else { return }
                // A movement can sit on both sides of a page boundary.
                let known = Set(transactions.map(\.id))
                transactions += page.transactions.filter { !known.contains($0.id) }
                nextPageToken = page.nextPageToken
                phase = .loaded
            } catch {
                guard !Task.isCancelled, asked == filter else { return }
                failure = NetworkFailure.of(error)
                // A later page that fails keeps the rows shown.
                if transactions.isEmpty { phase = .failed }
            }
            pageLoad = nil
            applySnapshot()
        }
    }

    private func loadMoreIfNeeded() {
        guard pageLoad == nil, phase == .loaded, let token = nextPageToken else { return }
        loadPage(after: token)
        applySnapshot()
    }

    // MARK: List

    private func configureDataSource() {
        let filterRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            let control = UISegmentedControl(items: Filter.allCases.map(\.title))
            control.selectedSegmentIndex = filter.rawValue
            control.addAction(UIAction { [weak self] action in
                guard let self, let control = action.sender as? UISegmentedControl,
                      let next = Filter(rawValue: control.selectedSegmentIndex), next != filter else { return }
                filter = next
                reload()
            }, for: .valueChanged)
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                control.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                control.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
            ])
            cell.backgroundConfiguration = .clear()
        }
        let rowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, WalletTransaction> { cell, _, transaction in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = Self.title(for: transaction)
            content.secondaryText = Self.subtitle(for: transaction)
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage.symbol(named: Self.symbol(for: transaction.kind))
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            let amount = UILabel()
            amount.attributedText = Self.amount(for: transaction)
            amount.adjustsFontForContentSizeCategory = true
            cell.accessories = [.customView(configuration: .init(customView: amount, placement: .trailing()))]
        }
        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            content.textProperties.color = .secondaryLabel
            switch item {
            case .loading, .loadingMore: content.text = "Loading…"
            case .failed:
                content.text = FailureCopy.row(for: self?.failure, fallback: "Couldn't load your wallet's history. Tap to try again.")
            case .empty: content.text = "Nothing here yet. Claims, stakes and gifts show up here."
            case .filter, .transaction: break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .filter:
                collectionView.dequeueConfiguredReusableCell(using: filterRegistration, for: indexPath, item: item)
            case .transaction(let transaction):
                collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: transaction)
            default:
                collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            if case .day(let day)? = self?.dataSource.sectionIdentifier(for: indexPath.section) {
                content.text = Self.dayTitle(for: day)
            } else if self?.dataSource.sectionIdentifier(for: indexPath.section) == .undated {
                content.text = "Earlier"
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            // Under the last section only.
            let isLast = indexPath.section == (self?.dataSource.snapshot().numberOfSections ?? 0) - 1
            content.text = isLast && indexPath.section > 0
                ? "Nothing in the app is sold for real money: likes are claimed and staked, gems are earned."
                : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.filter])
        snapshot.appendItems([.filter], toSection: .filter)
        switch phase {
        case .loading:
            snapshot.appendSections([.status])
            snapshot.appendItems([.loading], toSection: .status)
        case .failed:
            snapshot.appendSections([.status])
            snapshot.appendItems([.failed], toSection: .status)
        case .loaded where transactions.isEmpty:
            snapshot.appendSections([.status])
            snapshot.appendItems([.empty], toSection: .status)
        case .loaded:
            for group in Self.days(of: transactions) {
                let section: Section = group.day.map(Section.day) ?? .undated
                snapshot.appendSections([section])
                snapshot.appendItems(group.rows.map(Item.transaction), toSection: section)
            }
            if pageLoad != nil {
                snapshot.appendSections([.status])
                snapshot.appendItems([.loadingMore], toSection: .status)
            }
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The movements by day of the viewer's calendar, newest day first, in
    /// the server's order within a day; the undated ones last.
    nonisolated static func days(
        of transactions: [WalletTransaction], calendar: Calendar = .current
    ) -> [(day: Date?, rows: [WalletTransaction])] {
        var groups: [(day: Date?, rows: [WalletTransaction])] = []
        var undated: [WalletTransaction] = []
        for transaction in transactions {
            guard let date = transaction.createdAt else {
                undated.append(transaction)
                continue
            }
            let day = calendar.startOfDay(for: date)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].rows.append(transaction)
            } else if let index = groups.firstIndex(where: { $0.day == day }) {
                groups[index].rows.append(transaction)
            } else {
                groups.append((day, [transaction]))
            }
        }
        if !undated.isEmpty { groups.append((nil, undated)) }
        return groups
    }

    /// "Today", "Yesterday", then the weekday and date.
    nonisolated static func dayTitle(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return day.formatted(sameYear
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year())
    }

    // MARK: Wording

    static func title(for transaction: WalletTransaction) -> String {
        switch transaction.kind {
        case .claim: "Hourly claim"
        case .starterGift: "Starter gift"
        case .welcomeGift: "Welcome gift"
        case .stake: "Stake"
        case .stakePack: "×100 stake pack"
        case .countryUnlock: transaction.reference.map { "Country unlocked · \($0)" } ?? "Country unlocked"
        case .countryVisa: transaction.reference.map { "Country visa · \($0)" } ?? "Country visa"
        case .appIcon: "App icon"
        case .theme: "Theme"
        case .profileSlot: "Profile slot"
        case .handleChange: "Handle change"
        case .avatarFrame: "Avatar frame"
        case .animatedBanner: "Animated banner"
        case .cardStyle: "Card style"
        case .animatedAvatar: "Animated avatar"
        case .other: transaction.delta >= 0 ? "Credit" : "Spend"
        }
    }

    static func subtitle(for transaction: WalletTransaction, now: Date = Date()) -> String {
        let when = transaction.createdAt.map { date -> String in
            let age = RelativeAgeFormatter.short(from: date, to: now)
            return age == "now" ? "Just now" : "\(age) ago"
        }
        let balance = "Balance \(transaction.balanceAfter.formatted())"
        return [when, balance].compactMap { $0 }.joined(separator: " · ")
    }

    static func symbol(for kind: WalletTransaction.Kind) -> String {
        switch kind {
        case .claim: "clock.arrow.circlepath"
        case .starterGift, .welcomeGift: "gift"
        case .stake: AppSymbol.like.rawValue
        case .stakePack: "bolt"
        case .countryUnlock: "globe.europe.africa"
        case .countryVisa: "airplane"
        case .appIcon: "app.badge"
        case .theme: "paintpalette"
        case .profileSlot: "person.crop.circle.badge.plus"
        case .handleChange: "at"
        case .avatarFrame: "circle.dashed.inset.filled"
        case .animatedBanner: "rectangle.on.rectangle.angled"
        case .cardStyle: "rectangle.portrait.on.rectangle.portrait"
        case .animatedAvatar: "person.crop.circle.badge.checkmark"
        case .other: "circle.dashed"
        }
    }

    /// "+25 ♥" in green, "−3 ♥" in the label's colour; gems wear the gem.
    static func amount(for transaction: WalletTransaction) -> NSAttributedString {
        let font = UIFont.scaledMonospacedDigitSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        let sign = transaction.delta >= 0 ? "+" : "−"
        let color: UIColor = transaction.delta >= 0 ? .systemGreen : .label
        let text = NSMutableAttributedString(string: "\(sign)\(abs(transaction.delta).formatted()) ", attributes: [
            .font: font, .foregroundColor: color,
        ])
        let glyph = transaction.currency == .gems ? GemSymbol.glyphImage() : LikesSymbol.glyphImage()
        if let glyph {
            let attachment = NSTextAttachment(image: glyph)
            text.append(NSAttributedString(attachment: attachment))
        }
        return text
    }
}

extension WalletHistoryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // The last rows on screen: the next page.
        guard case .transaction(let transaction)? = dataSource.itemIdentifier(for: indexPath),
              let index = transactions.firstIndex(of: transaction) else { return }
        if index >= transactions.count - 5 { loadMoreIfNeeded() }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .failed
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .failed { reload() }
    }
}
