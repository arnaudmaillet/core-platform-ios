import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Your Reports (#399, DSA Art. 16(5)):
/// what the viewer reported, newest first, and what became of each report.
/// Pages in as the list scrolls.
final class YourReportsViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    private enum Item: Hashable {
        case report(FiledReport)
        case empty
        case loadingMore
        case retry
    }

    private let history: any ReportHistoryProviding
    private var reports: [FiledReport] = []
    private var nextPageToken: String?
    private var phase: Phase = .loading
    private var isLoadingPage = false
    private var pageFailed = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(history: any ReportHistoryProviding) {
        self.history = history
        super.init(nibName: nil, bundle: nil)
        title = "Your Reports"
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
        loadPage()
    }

    /// The first page, or the next one after `nextPageToken`.
    private func loadPage() {
        guard !isLoadingPage else { return }
        isLoadingPage = true
        pageFailed = false
        applySnapshot()
        let token = reports.isEmpty ? nil : nextPageToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await history.myReports(pageToken: token)
                let known = Set(reports.map(\.id))
                reports += page.reports.filter { !known.contains($0.id) }
                nextPageToken = page.nextPageToken
                phase = .loaded
            } catch {
                if reports.isEmpty { phase = .failed } else { pageFailed = true }
            }
            isLoadingPage = false
            applySnapshot()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func title(of report: FiledReport) -> String {
        switch report.subject {
        case .post: "Post"
        case .comment: "Comment"
        case .profile: "Account"
        case .other: "Content"
        }
    }

    /// "Hate speech · 3 Oct 2026".
    static func detail(of report: FiledReport) -> String {
        [report.category, report.reportedAt.map { dateFormatter.string(from: $0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func outcome(_ outcome: FiledReport.Outcome) -> (text: String, color: UIColor) {
        switch outcome {
        case .underReview: ("In Review", .secondaryLabel)
        case .actionTaken: ("Action Taken", .systemGreen)
        case .noViolation: ("No Violation", .secondaryLabel)
        }
    }

    static let explanation = "In Review: we haven't finished looking at it. Action Taken: it broke our rules and we acted on it; to protect everyone's privacy, we don't say how. No Violation: we didn't find that it broke our rules."

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            cell.accessories = []
            switch item {
            case .report(let report):
                var content = UIListContentConfiguration.subtitleCell()
                content.text = Self.title(of: report)
                content.secondaryText = Self.detail(of: report)
                content.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = content
                let outcome = Self.outcome(report.outcome)
                cell.accessories = [.label(text: outcome.text, options: .init(tintColor: outcome.color, font: .appFont(forTextStyle: .subheadline), adjustsFontForContentSizeCategory: true))]
                cell.accessibilityLabel = "\(Self.title(of: report)), \(Self.detail(of: report)), \(outcome.text)"
            case .empty:
                var content = UIListContentConfiguration.cell()
                content.text = "You haven't reported anything."
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            case .loadingMore:
                var content = UIListContentConfiguration.cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            case .retry:
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
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = switch self?.phase {
            case .failed: "Couldn't load your reports."
            case .loaded where self?.reports.isEmpty == false: Self.explanation
            default: "When you report a post or an account, you can follow it here."
            }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch phase {
        case .loading:
            snapshot.appendItems([.loadingMore])
        case .failed:
            snapshot.appendItems([isLoadingPage ? .loadingMore : .retry])
        case .loaded:
            snapshot.appendItems(reports.isEmpty ? [.empty] : reports.map(Item.report))
            if nextPageToken != nil {
                snapshot.appendItems([pageFailed ? .retry : .loadingMore])
            }
        }
        snapshot.reloadSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension YourReportsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .retry
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .retry {
            if phase == .failed { phase = .loading }
            loadPage()
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // The next page once its placeholder row shows; deferred so the
        // snapshot isn't applied from inside the display pass.
        if dataSource.itemIdentifier(for: indexPath) == .loadingMore, phase == .loaded, !pageFailed {
            DispatchQueue.main.async { [weak self] in self?.loadPage() }
        }
    }
}
