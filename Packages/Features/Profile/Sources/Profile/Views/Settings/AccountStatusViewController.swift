import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Account Status (#390): whether the
/// account is under any restriction, and which. A restriction that names its
/// decision opens why it was applied, and an appeal
/// (`DecisionDetailViewController`).
final class AccountStatusViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded([AccountRestriction])
        case failed
    }

    private enum Item: Hashable {
        case summary
        case restriction(AccountRestriction)
        case retry
    }

    private let status: any AccountStatusProviding
    private let reviewer: (any ModerationDecisionReviewing)?
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(status: any AccountStatusProviding, reviewer: (any ModerationDecisionReviewing)? = nil) {
        self.status = status
        self.reviewer = reviewer
        super.init(nibName: nil, bundle: nil)
        title = "Account Status"
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
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
        load()
    }

    private func load() {
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                phase = .loaded(try await status.activeRestrictions())
            } catch {
                phase = .failed
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// "Since 1 Oct 2026 · Until 8 Oct 2026", "Since 1 Oct 2026 · Permanent".
    static func period(of restriction: AccountRestriction) -> String {
        var parts: [String] = []
        if let since = restriction.since { parts.append("Since \(dateFormatter.string(from: since))") }
        parts.append(restriction.until.map { "Until \(dateFormatter.string(from: $0))" } ?? "Permanent")
        return parts.joined(separator: " · ")
    }

    static func summary(for phase: Phase) -> (title: String, symbol: String, color: UIColor) {
        switch phase {
        case .loading: ("Checking your account…", "hourglass", .secondaryLabel)
        case .failed: ("Couldn't check your account status.", "exclamationmark.circle", .secondaryLabel)
        case .loaded(let restrictions) where restrictions.isEmpty: ("No restrictions on your account", "checkmark.shield", .systemGreen)
        case .loaded: ("Your account has restrictions", "exclamationmark.triangle", .systemOrange)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .summary:
                cell.accessories = []
                let summary = Self.summary(for: phase)
                var content = UIListContentConfiguration.cell()
                content.text = summary.title
                content.image = UIImage(systemName: summary.symbol)
                content.imageProperties.tintColor = summary.color
                cell.contentConfiguration = content
            case .restriction(let restriction):
                var content = UIListContentConfiguration.subtitleCell()
                content.text = restriction.title
                content.secondaryText = Self.period(of: restriction)
                content.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = content
                cell.accessories = canOpen(restriction) ? [.disclosureIndicator()] : []
            case .retry:
                cell.accessories = []
                var content = UIListContentConfiguration.cell()
                content.text = "Try Again"
                content.textProperties.color = .tintColor
                cell.contentConfiguration = content
            }
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            if indexPath.section == 0, let self, case .loaded(let restrictions) = phase, !restrictions.isEmpty {
                content.text = Self.footer(canOpenAll: restrictions.allSatisfy(canOpen))
            } else {
                content.text = nil
            }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func canOpen(_ restriction: AccountRestriction) -> Bool {
        reviewer != nil && restriction.decisionID != nil
    }

    static func footer(canOpenAll: Bool) -> String {
        canOpenAll
            ? "Tap a restriction to see why it was applied. If you think it's a mistake, you can appeal it."
            : "Contact support to ask about a decision that doesn't show why it was made."
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems([.summary])
        switch phase {
        case .loaded(let restrictions): snapshot.appendItems(restrictions.map(Item.restriction))
        case .failed: snapshot.appendItems([.retry])
        case .loading: break
        }
        snapshot.reconfigureItems([.summary])
        snapshot.reloadSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension AccountStatusViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .retry: true
        case .restriction(let restriction): canOpen(restriction)
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .retry:
            load()
        case .restriction(let restriction):
            guard let reviewer, let decisionID = restriction.decisionID else { return }
            navigationController?.pushViewController(
                DecisionDetailViewController(restriction: restriction, decisionID: decisionID, reviewer: reviewer),
                animated: true
            )
        default:
            break
        }
    }
}
