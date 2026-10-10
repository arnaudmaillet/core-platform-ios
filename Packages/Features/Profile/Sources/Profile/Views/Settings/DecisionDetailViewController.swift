import DesignSystem
import UIKit

/// Account Status → a restriction (#390): why it was imposed — the decision's
/// Statement of Reasons (DSA Art. 17) — and a way to appeal it (Art. 20).
/// Once appealed, the appeal's status comes from the server (#576): under
/// review, then upheld or reversed with the reviewer's reasons.
final class DecisionDetailViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(DecisionStatement)
        case failed
    }

    enum Section: Int, CaseIterable {
        case decision, facts, rule, appeal
    }

    enum Item: Hashable {
        case restriction
        case detail(title: String, value: String)
        case text(String)
        case appeal
        case appealStatus(FiledAppeal)
        case retry
        /// A detail-shaped bone while the statement loads (charter P8).
        case skeleton(Int)
    }

    private let restriction: AccountRestriction
    private let decisionID: String
    private let reviewer: any ModerationDecisionReviewing
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    /// This decision's appeal, as the server holds it; nil before one is filed.
    private var appeal: FiledAppeal?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// Whether the decision section last drew bones: leaving them cross-fades
    /// (P10).
    private var isShowingSkeleton = false

    init(restriction: AccountRestriction, decisionID: String, reviewer: any ModerationDecisionReviewing) {
        self.restriction = restriction
        self.decisionID = decisionID
        self.reviewer = reviewer
        super.init(nibName: nil, bundle: nil)
        title = restriction.title
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
                async let appeals = try? reviewer.myAppeals()
                let statement = try await reviewer.statementOfReasons(decisionID: decisionID)
                appeal = await Self.appeal(for: decisionID, in: appeals ?? [])
                phase = .loaded(statement)
            } catch {
                phase = .failed
            }
        }
    }

    /// Re-reads the appeal after filing one: the server's word, not the
    /// app's guess.
    private func refreshAppeal() {
        Task { [weak self] in
            guard let self, let appeals = try? await reviewer.myAppeals() else { return }
            appeal = Self.appeal(for: decisionID, in: appeals) ?? appeal
            applySnapshot()
        }
    }

    /// The account's own appeal on `decisionID` (a reporter's isn't theirs to see here).
    static func appeal(for decisionID: String, in appeals: [FiledAppeal]) -> FiledAppeal? {
        appeals.first { $0.decisionID == decisionID && !$0.byReporter }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func decidedBy(automated: Bool) -> String {
        automated ? "An automated system" : "A member of our safety team"
    }

    /// The appeal row's words: what stage it is at, and when.
    static func appealStatusText(_ appeal: FiledAppeal) -> (title: String, detail: String?) {
        let day = { (date: Date?) in date.map { dateFormatter.string(from: $0) } }
        switch appeal.status {
        case .pending:
            return ("Appeal under review", day(appeal.filedAt).map { "Sent on \($0)" })
        case .upheld:
            return ("Appeal reviewed: the decision stands", day(appeal.resolvedAt).map { "Decided on \($0)" })
        case .overturned:
            return ("Appeal reviewed: the decision was reversed", day(appeal.resolvedAt).map { "Decided on \($0)" })
        }
    }

    static func appealFooter(_ appeal: FiledAppeal?) -> String {
        switch appeal?.status {
        case nil: "If you think this decision is wrong, tell us why and we'll review it again."
        case .pending?: "We're reviewing the decision again. You'll see the outcome here."
        case .upheld?, .overturned?: appeal.map { $0.reasons.isEmpty ? "" : "Reviewer's reasons: \($0.reasons)" } ?? ""
        }
    }

    private static func headerText(_ section: Section) -> String? {
        switch section {
        case .decision: nil
        case .facts: "What Happened"
        case .rule: "Rule Applied"
        case .appeal: nil
        }
    }

    private func footerText(_ section: Section) -> String? {
        switch (section, phase) {
        case (.decision, .failed):
            "Couldn't load why this decision was made."
        case (.rule, .loaded(let statement)) where !statement.policyVersion.isEmpty:
            "Policy version: \(statement.policyVersion)"
        case (.appeal, .loaded):
            Self.appealFooter(appeal)
        default:
            nil
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            switch item {
            case .restriction:
                var content = UIListContentConfiguration.subtitleCell()
                content.text = restriction.title
                content.secondaryText = AccountStatusViewController.period(of: restriction)
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: "exclamationmark.triangle")
                content.imageProperties.tintColor = .systemOrange
                cell.contentConfiguration = content
            case .detail(let title, let value):
                var content = UIListContentConfiguration.valueCell()
                content.text = title
                content.secondaryText = value
                content.prefersSideBySideTextAndSecondaryText = false
                cell.contentConfiguration = content
            case .text(let text):
                var content = UIListContentConfiguration.cell()
                content.text = text
                cell.contentConfiguration = content
            case .appeal:
                var content = UIListContentConfiguration.cell()
                content.text = "Appeal This Decision"
                content.textProperties.color = .tintColor
                cell.contentConfiguration = content
            case .appealStatus(let appeal):
                var content = UIListContentConfiguration.subtitleCell()
                let text = Self.appealStatusText(appeal)
                content.text = text.title
                content.secondaryText = text.detail
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: appeal.status == .pending ? "clock" : "checkmark.circle")
                content.imageProperties.tintColor = appeal.status == .overturned ? .systemGreen : .secondaryLabel
                cell.contentConfiguration = content
            case .retry:
                var content = UIListContentConfiguration.cell()
                content.text = "Try Again"
                content.textProperties.color = .tintColor
                cell.contentConfiguration = content
            case .skeleton:
                // Drawn by `SettingsSkeletonRowCell`.
                break
            }
        }
        let skeletonRegistration = UICollectionView.CellRegistration<SettingsSkeletonRowCell, Int> { cell, _, index in
            cell.configure(redacting: Self.detailPlaceholder(index))
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .skeleton(let index) = item {
                return collectionView.dequeueConfiguredReusableCell(using: skeletonRegistration, for: indexPath, item: index)
            }
            return collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.headerText)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap { self?.footerText($0) }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for (section, items) in Self.layout(phase: phase, appeal: appeal) {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers)

        let wasShowingSkeleton = isShowingSkeleton
        isShowingSkeleton = phase == .loading
        if wasShowingSkeleton, !isShowingSkeleton {
            collectionView.crossfadeFromSkeleton { [dataSource, snapshot] in
                dataSource?.apply(snapshot, animatingDifferences: false)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// The screen's sections and rows for `phase`. While the statement loads
    /// the decision section carries bones in the detail rows' place — the
    /// usual Policy / Decided on / Decided by — rather than nothing at all.
    static func layout(phase: Phase, appeal: FiledAppeal?) -> [(Section, [Item])] {
        switch phase {
        case .loading:
            return [(.decision, [.restriction, .skeleton(0), .skeleton(1), .skeleton(2)])]
        case .failed:
            return [(.decision, [.restriction, .retry])]
        case .loaded(let statement):
            var details: [Item] = [.restriction, .detail(title: "Policy", value: statement.policy)]
            if let decidedAt = statement.decidedAt {
                details.append(.detail(title: "Decided on", value: Self.dateFormatter.string(from: decidedAt)))
            }
            details.append(.detail(title: "Decided by", value: Self.decidedBy(automated: statement.automated)))
            var layout: [(Section, [Item])] = [(.decision, details)]
            if !statement.facts.isEmpty {
                layout.append((.facts, [.text(statement.facts)]))
            }
            if !statement.legalGround.isEmpty {
                layout.append((.rule, [.text(statement.legalGround)]))
            }
            layout.append((.appeal, [appeal.map(Item.appealStatus) ?? .appeal]))
            return layout
        }
    }

    /// A detail row with sample words, stacked like the real ones; only the
    /// bones' widths come from them.
    private static func detailPlaceholder(_ index: Int) -> UIListContentConfiguration {
        let samples = [("Policy", "Community guidelines"), ("Decided on", "4 Oct 2026"), ("Decided by", "A member of our safety team")]
        let sample = samples[index % samples.count]
        var content = UIListContentConfiguration.valueCell()
        content.text = sample.0
        content.secondaryText = sample.1
        content.prefersSideBySideTextAndSecondaryText = false
        return content
    }

    // MARK: - Appeal

    private func presentAppeal() {
        let composer = AppealComposerViewController(restriction: restriction) { [weak self] statement in
            guard let self else { throw AppealError.notFound }
            return try await reviewer.fileAppeal(decisionID: decisionID, statement: statement)
        }
        composer.onFiled = { [weak self] date in
            guard let self else { return }
            // Shown at once as filed; the server's own record follows.
            appeal = FiledAppeal(id: "", decisionID: decisionID, status: .pending, filedAt: date)
            applySnapshot()
            refreshAppeal()
        }
        present(UINavigationController(rootViewController: composer), animated: true)
    }
}

extension DecisionDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .appeal, .retry: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .appeal: presentAppeal()
        case .retry: load()
        default: break
        }
    }
}

/// The appeal itself: the holder says why the decision is wrong. The server
/// refuses an empty statement, so Send waits for some text.
final class AppealComposerViewController: UIViewController, UITextViewDelegate {
    static let maximumLength = 2_000

    var onFiled: ((Date) -> Void)?

    private let intro: String
    private let file: @MainActor (String) async throws -> Date
    private let textView = UITextView()
    private let placeholder = UILabel()
    private var isSending = false

    convenience init(restriction: AccountRestriction, file: @escaping @MainActor (String) async throws -> Date) {
        self.init(
            intro: "Tell us why you think \"\(restriction.title)\" was a mistake. Someone will review the decision again.",
            file: file
        )
    }

    /// `intro`: what is being appealed, and what happens next.
    init(intro: String, file: @escaping @MainActor (String) async throws -> Date) {
        self.intro = intro
        self.file = file
        super.init(nibName: nil, bundle: nil)
        title = "Appeal"
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = sendItem()

        let intro = UILabel()
        intro.text = self.intro
        intro.font = .appFont(forTextStyle: .subheadline)
        intro.adjustsFontForContentSizeCategory = true
        intro.textColor = .secondaryLabel
        intro.numberOfLines = 0

        textView.font = .appFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.delegate = self
        textView.accessibilityLabel = "Your appeal"

        placeholder.text = "Your reasons"
        placeholder.font = textView.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isAccessibilityElement = false
        textView.addSubview(placeholder)

        let stack = UIStackView(arrangedSubviews: [intro, textView])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
        ])
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    private func sendItem() -> UIBarButtonItem {
        UIBarButtonItem(title: "Send", style: .prominent, target: self, action: #selector(send))
    }

    static func canSend(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.count <= maximumLength
    }

    private func refresh() {
        placeholder.isHidden = !textView.text.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = Self.canSend(textView.text) && !isSending
    }

    func textViewDidChange(_ textView: UITextView) {
        refresh()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let current = textView.text as NSString
        return current.replacingCharacters(in: range, with: text).count <= Self.maximumLength
    }

    @objc private func send() {
        guard Self.canSend(textView.text), !isSending else { return }
        isSending = true
        textView.isEditable = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        let statement = textView.text ?? ""
        Task { [weak self] in
            guard let self else { return }
            do {
                let filedAt = try await file(statement)
                HapticNotification().notificationOccurred(.success)
                onFiled?(filedAt)
                dismiss(animated: true)
            } catch {
                HapticNotification().notificationOccurred(.error)
                isSending = false
                textView.isEditable = true
                navigationItem.rightBarButtonItem = sendItem()
                refresh()
                let failure = Self.failure(error)
                let alert = UIAlertController(title: failure.title, message: failure.message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    static func failure(_ error: Error) -> (title: String, message: String) {
        switch error as? AppealError {
        case .windowClosed:
            ("Too Late to Appeal", "The time to appeal this decision has passed.")
        case .notAppealable:
            ("This Decision Can't Be Appealed", "The law requires this kind of decision, so it can't be reviewed again.")
        case .emptyStatement:
            ("Say Why", "Write a few words about why the decision is wrong.")
        case .notFound:
            ("Decision Not Found", "This decision may have been lifted already.")
        default:
            ("Couldn't Send Your Appeal", "Check your connection and try again.")
        }
    }
}
