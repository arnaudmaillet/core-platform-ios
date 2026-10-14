import CoreNetworking
import CoreStorage
import DesignSystem
import PostGrid
import UIKit

/// Settings → Wallet and Purchases (#400): the wallet's history, from the
/// server (wallet.v1 `ListWalletTransactions`) — every claim, stake and gift,
/// newest first, page by page, for both currencies or one.
///
/// Nothing is sold for real money (the backend's decision of 2026-10-08), so
/// there is no Restore Purchases and no spending limit: the page is the
/// ledger, and a kind this build does not know is shown plainly rather than
/// hidden.
@MainActor
final class WalletHistoryViewController: UIViewController {
    enum Filter: Int, CaseIterable {
        case all, points, gems

        var title: String {
            switch self {
            case .all: "All"
            case .points: "Points"
            case .gems: GemSymbol.name
            }
        }

        var currency: WalletTransaction.Currency? {
            switch self {
            case .all: nil
            case .points: .points
            case .gems: .gems
            }
        }
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
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

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
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .filter:
                collectionView.dequeueConfiguredReusableCell(using: filterRegistration, for: indexPath, item: item)
            case .transaction(let transaction):
                collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: transaction)
            default:
                collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: item)
            }
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 1
                ? "Nothing in the app is sold for real money: points are claimed and staked, gems are earned."
                : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([.filter], toSection: 0)
        switch phase {
        case .loading: snapshot.appendItems([.loading], toSection: 1)
        case .failed: snapshot.appendItems([.failed], toSection: 1)
        case .loaded where transactions.isEmpty: snapshot.appendItems([.empty], toSection: 1)
        case .loaded:
            snapshot.appendItems(transactions.map(Item.transaction), toSection: 1)
            if pageLoad != nil { snapshot.appendItems([.loadingMore], toSection: 1) }
        }
        dataSource.apply(snapshot, animatingDifferences: false)
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
        let glyph = transaction.currency == .gems ? GemSymbol.glyphImage() : PointsSymbol.glyphImage()
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
        if indexPath.section == 1, indexPath.item >= transactions.count - 5 { loadMoreIfNeeded() }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .failed
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .failed { reload() }
    }
}
