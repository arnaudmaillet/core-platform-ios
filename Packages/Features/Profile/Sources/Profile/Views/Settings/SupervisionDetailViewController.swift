import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import MediaCore
import UIKit

/// Settings → Family and Teens → a supervision (#417): who the other side is,
/// since when, and End Supervision. Either side may end it (backend #670);
/// the other side is told (#848), and the confirmation says so.
///
/// **The overview (backend #670 parts 2 and 3).** A supervisor sees the
/// teen's daily time in the app over the last 7 days and the limits, with
/// Edit Limits. A teen sees exactly the same overview of themselves on each
/// supervisor's page, read-only: what their supervisors see.
final class SupervisionDetailViewController: UIViewController {
    enum Section: Hashable {
        case profiles, screenTime, limits, about, end
    }

    enum Item: Hashable {
        case profile(SupervisionProfile)
        case overviewLoading
        case overviewFailed
        case day(ScreenTimeDay)
        case noTime
        case limit(title: String, value: String)
        case noLimits
        case editLimits
        case role
        case since
        case end
    }

    let supervision: Supervision
    private let list: SupervisionListModel
    /// The teen's overview; nil when the deployment serves none.
    let overview: SupervisionOverviewModel?
    private let imagePipeline: ImagePipeline?
    private let router: (any Router)?
    /// The supervision ended, or was found already gone (true): the opener
    /// steps back and says which.
    private let onEnded: (SupervisionDetailViewController, Supervision, Bool) -> Void
    private var collectionView: UICollectionView!
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let avatarLoads = RowImageLoads(size: .avatar)
    private(set) var isEnding = false
    /// Confirms the end; a test hands in its own (an action sheet never
    /// finishes presenting in the test host).
    var confirmEnd: ((@escaping () -> Void) -> Void)?

    /// The viewer is the teen: the other side supervises them.
    private var viewerIsTeen: Bool { supervision.otherRole == .supervisor }

    init(
        supervision: Supervision,
        list: SupervisionListModel,
        overviewing: (any SupervisionOverviewing)? = nil,
        imagePipeline: ImagePipeline?,
        router: (any Router)?,
        onEnded: @escaping (SupervisionDetailViewController, Supervision, Bool) -> Void
    ) {
        self.supervision = supervision
        self.list = list
        // A supervisor reads its teen's overview; a teen reads their own.
        overview = overviewing.map {
            SupervisionOverviewModel(
                manager: $0, teenAccountID: supervision.otherRole == .teen ? supervision.otherAccountID : nil
            )
        }
        self.imagePipeline = imagePipeline
        self.router = router
        self.onEnded = onEnded
        super.init(nibName: nil, bundle: nil)
        title = supervision.name
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
        overview?.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        loadOverview()
    }

    private func loadOverview() {
        guard let overview else { return }
        Task { await overview.load() }
    }

    static func header(_ section: Section) -> String? {
        switch section {
        case .screenTime: SupervisionCopy.screenTimeHeader
        case .limits: SupervisionCopy.limitsHeader
        default: nil
        }
    }

    static func footer(_ section: Section, supervision: Supervision) -> String? {
        switch section {
        case .profiles:
            supervision.otherRole == .teen
                ? "The teen's profiles. They see that you supervise them."
                : "This person sees your daily time in the app and your limits, below, and can change the limits."
        case .screenTime: SupervisionCopy.screenTimeFooter
        case .limits, .about: nil
        case .end:
            supervision.otherRole == .supervisor
                ? "\(supervision.handleText) is told when you end it. Supervision also ends by itself when you turn 18."
                : "\(supervision.handleText) is told when you end it. It also ends by itself when they turn 18."
        }
    }

    /// Under the limits: the rule, and who changed them last when known (a
    /// teen knows their supervisors; a supervisor's own id isn't on hand).
    private func limitsFooter() -> String? {
        guard let state = overview?.overview?.limits, state.limits != nil else { return nil }
        let changedBy: String? = state.setByAccountID.flatMap { id in
            list.supervisions.first { $0.otherAccountID == id }?.handleText
        }
        return SupervisionCopy.limitsFooter(
            teen: viewerIsTeen, teenName: supervision.name, changedBy: changedBy, changedAt: state.setAt
        )
    }

    /// The overview's rows: the days, newest first, and the limits.
    static func overviewItems(_ phase: SupervisionOverviewModel.Phase, canEdit: Bool) -> (time: [Item], limits: [Item]) {
        switch phase {
        case .loading: return ([.overviewLoading], [])
        case .failed: return ([.overviewFailed], [])
        case .loaded(let overview):
            let days: [Item] = overview.screenTime.isEmpty ? [.noTime] : overview.screenTime.map(Item.day)
            var limits: [Item] = overview.limits.limits.map { limits in
                SupervisionCopy.limitRows(limits).map { Item.limit(title: $0.title, value: $0.value) }
            } ?? [.noLimits]
            if canEdit { limits.append(.editLimits) }
            return (days, limits)
        }
    }

    private func configureDataSource() {
        let person = UICollectionView.CellRegistration<PersonListCell, SupervisionProfile> { [weak self] cell, _, profile in
            cell.configure(with: PersonRowContent(
                displayName: profile.name,
                handle: "@\(profile.handle)",
                monogram: MonogramAvatarView.monogram(name: profile.displayName, handle: profile.handle)
            ))
            cell.setAvatarImage(nil)
            if self?.router != nil { cell.accessories.append(.disclosureIndicator()) }
            self?.avatarLoads.load(profile.avatarURL, using: self?.imagePipeline, for: cell) { [weak cell] image, _ in
                cell?.setAvatarImage(image)
            }
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            cell.accessibilityTraits.remove(.button)
            switch item {
            case .role:
                content.text = "Role"
                content.secondaryText = SupervisionCopy.roleText(supervision)
            case .since:
                content.text = "Linked"
                content.secondaryText = SupervisionCopy.sinceText(supervision.since)
            case .day(let day):
                content.text = SupervisionCopy.dayText(day.day)
                content.secondaryText = SupervisionCopy.minutesText(day.minutes)
            case .limit(let title, let value):
                content.text = title
                content.secondaryText = value
            case .noTime:
                content = .cell()
                content.text = SupervisionCopy.noTimeYet
                content.textProperties.color = .secondaryLabel
            case .noLimits:
                content = .cell()
                content.text = SupervisionCopy.noLimits
                content.textProperties.color = .secondaryLabel
            case .overviewLoading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .overviewFailed:
                content = .cell()
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(for: overview?.failure, fallback: SupervisionCopy.overviewFailedRow)
                content.textProperties.color = .secondaryLabel
                cell.accessibilityTraits.insert(.button)
            case .editLimits:
                content = .cell()
                content.text = SupervisionCopy.editLimitsTitle
                content.textProperties.color = .tintColor
                cell.accessibilityTraits.insert(.button)
            case .end:
                content = .cell()
                content.text = SupervisionCopy.endAction
                content.textProperties.color = isEnding ? .secondaryLabel : .systemRed
                content.textProperties.alignment = .center
                cell.accessibilityTraits.insert(.button)
            case .profile:
                break
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .profile(let profile) = item {
                return collectionView.dequeueConfiguredReusableCell(using: person, for: indexPath, item: profile)
            }
            return collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.header()
            content.text = dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = dataSource.sectionIdentifier(for: indexPath.section).flatMap { section in
                section == .limits ? self.limitsFooter() : Self.footer(section, supervision: self.supervision)
            }
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
        if !supervision.profiles.isEmpty {
            snapshot.appendSections([.profiles])
            snapshot.appendItems(supervision.profiles.map(Item.profile), toSection: .profiles)
        }
        if let overview {
            let items = Self.overviewItems(overview.phase, canEdit: overview.canEditLimits)
            snapshot.appendSections([.screenTime])
            snapshot.appendItems(items.time, toSection: .screenTime)
            if !items.limits.isEmpty {
                snapshot.appendSections([.limits])
                snapshot.appendItems(items.limits, toSection: .limits)
            }
        }
        snapshot.appendSections([.about, .end])
        snapshot.appendItems([.role, .since], toSection: .about)
        snapshot.appendItems([.end], toSection: .end)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Limits

    func openLimitsEditor() {
        guard let overview, overview.canEditLimits, overview.overview != nil else { return }
        let editor = SupervisionLimitsViewController(model: overview, teenName: supervision.name) { [weak self] editor in
            editor.navigationController?.popViewController(animated: true)
            if let self { Feedback.success(SupervisionCopy.limitsSaved, from: self) }
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    // MARK: End

    private func askToEnd() {
        guard !isEnding else { return }
        let end: () -> Void = { [weak self] in self?.end() }
        if let confirmEnd { return confirmEnd(end) }
        let sheet = UIAlertController(
            title: SupervisionCopy.endTitle(supervision),
            message: SupervisionCopy.endMessage(supervision),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: SupervisionCopy.endAction, style: .destructive) { _ in end() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    /// Ends it once the server agrees; a refusal keeps the screen as it was.
    func end() {
        guard !isEnding else { return }
        isEnding = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await list.end(supervision)
                onEnded(self, supervision, false)
            } catch SupervisionError.notFound {
                // Already gone (the other side ended it, or the teen turned
                // 18): the list has dropped it; the opener says so.
                onEnded(self, supervision, true)
            } catch {
                isEnding = false
                applySnapshot()
                Feedback.failure(
                    SupervisionCopy.failureText(error, teen: viewerIsTeen, fallback: "Couldn't end supervision"),
                    from: self
                )
            }
        }
    }
}

extension SupervisionDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile: router != nil
        case .end: !isEnding
        case .overviewFailed, .editLimits: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .profile(let profile):
            router?.route(to: .profile(ProfileID(profile.profileID), stub: nil))
        case .overviewFailed:
            loadOverview()
        case .editLimits:
            openLimitsEditor()
        case .end:
            askToEnd()
        default:
            break
        }
    }
}
