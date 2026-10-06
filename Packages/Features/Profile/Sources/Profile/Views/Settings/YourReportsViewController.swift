import DesignSystem
import UIKit

/// Settings → Safety and Interactions → Your Reports (#399, DSA Art. 16(5)):
/// what the viewer reported, newest first, and what became of each report.
/// Pages in as the list scrolls.
///
/// A decided report can be appealed by its reporter (DSA Art. 20(1), #576):
/// tapping it offers the appeal, and its row then follows the appeal — under
/// review, then upheld or reversed, with the reviewer's reasons on tap.
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
    /// Files and reads appeals; nil leaves reports read-only.
    private let appeals: (any ModerationDecisionReviewing)?
    /// The viewer's appeals as a reporter, by decision.
    private var appealsByDecision: [String: FiledAppeal] = [:]
    private var reports: [FiledReport] = []
    private var nextPageToken: String?
    private var phase: Phase = .loading
    private var isLoadingPage = false
    private var pageFailed = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(history: any ReportHistoryProviding, appeals: (any ModerationDecisionReviewing)? = nil) {
        self.history = history
        self.appeals = appeals
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
        loadAppeals()
    }

    private func loadAppeals() {
        guard let appeals else { return }
        Task { [weak self] in
            guard let self, let mine = try? await appeals.myAppeals() else { return }
            appealsByDecision = Self.reporterAppeals(mine)
            applySnapshot()
        }
    }

    /// The reporter's appeals, by the decision they're against.
    static func reporterAppeals(_ appeals: [FiledAppeal]) -> [String: FiledAppeal] {
        Dictionary(appeals.filter(\.byReporter).map { ($0.decisionID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// "Appeal under review", "Appeal: decision stands", "Appeal: decision reversed".
    static func appealText(_ appeal: FiledAppeal) -> String {
        switch appeal.status {
        case .pending: "Appeal under review"
        case .upheld: "Appeal: decision stands"
        case .overturned: "Appeal: decision reversed"
        }
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
    static let appealHint = "If you disagree with a decision, tap the report to appeal it."

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.accessories = []
            switch item {
            case .report(let report):
                var content = UIListContentConfiguration.subtitleCell()
                content.text = Self.title(of: report)
                let appeal = report.decisionID.flatMap { self?.appealsByDecision[$0] }
                content.secondaryText = [Self.detail(of: report), appeal.map(Self.appealText)]
                    .compactMap { $0 }.joined(separator: "\n")
                content.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = content
                let outcome = Self.outcome(report.outcome)
                cell.accessories = [.label(text: outcome.text, options: .init(tintColor: outcome.color, font: .appFont(forTextStyle: .subheadline), adjustsFontForContentSizeCategory: true))]
                cell.accessibilityLabel = [Self.title(of: report), Self.detail(of: report), outcome.text, appeal.map(Self.appealText)]
                    .compactMap { $0 }.joined(separator: ", ")
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
            case .loaded where self?.reports.isEmpty == false:
                self?.appeals == nil ? Self.explanation : Self.explanation + " " + Self.appealHint
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

    /// Whether tapping the report does anything: an appeal to file, or a
    /// resolved one to read.
    private func isActionable(_ report: FiledReport) -> Bool {
        guard appeals != nil, let decisionID = report.decisionID else { return false }
        guard let appeal = appealsByDecision[decisionID] else { return true }
        return appeal.status != .pending
    }

    private func open(_ report: FiledReport) {
        guard let appeals, let decisionID = report.decisionID else { return }
        if let appeal = appealsByDecision[decisionID] {
            guard appeal.status != .pending else { return }
            let alert = UIAlertController(
                title: Self.appealText(appeal),
                message: appeal.reasons.isEmpty ? nil : appeal.reasons,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            return present(alert, animated: true)
        }
        let subject = Self.title(of: report).lowercased()
        let composer = AppealComposerViewController(
            intro: Self.appealIntro(report, subject: subject)
        ) { statement in
            try await appeals.fileAppeal(decisionID: decisionID, statement: statement)
        }
        composer.onFiled = { [weak self] date in
            guard let self else { return }
            appealsByDecision[decisionID] = FiledAppeal(
                id: "", decisionID: decisionID, status: .pending, filedAt: date, byReporter: true
            )
            applySnapshot()
            loadAppeals()
        }
        present(UINavigationController(rootViewController: composer), animated: true)
    }

    static func appealIntro(_ report: FiledReport, subject: String) -> String {
        switch report.outcome {
        case .noViolation:
            "We didn't find that this \(subject) broke our rules. If you think we got it wrong, tell us why and someone will look at it again."
        default:
            "If you think our decision on this \(subject) was wrong, tell us why and someone will look at it again."
        }
    }
}

extension YourReportsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .retry: true
        case .report(let report): isActionable(report)
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .report(let report) = dataSource.itemIdentifier(for: indexPath) {
            return open(report)
        }
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
