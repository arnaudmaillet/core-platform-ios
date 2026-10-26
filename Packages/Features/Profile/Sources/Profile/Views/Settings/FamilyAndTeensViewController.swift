import CoreNavigation
import CoreNetworking
import CoreStorage
import DesignSystem
import MediaCore
import UIKit

/// A settings page that can open another section (Family and Teens points at
/// Privacy, What You See…). `SettingsViewController` hands it the way.
@MainActor
protocol SettingsSectionLinking: AnyObject {
    var openSection: ((SettingsSection) -> Void)? { get set }
}

/// Settings → Family and Teens (#401): the protections an account aged 13–17
/// starts with, each opening the page that changes it. No switch turns them
/// all off at once (decided 2026-10-07): the server starts the profile
/// private, with messages from followers, location hidden, sensitive content
/// at Less and quiet hours from 22:00 to 07:00; the device adds a 60-minute
/// daily limit and no purchases (`TeenProtections`).
///
/// An adult sees the same list as what a teen account gets, without links.
///
/// ⚠️ **AN UNREAD AGE IS NOT AN ADULT ONE (#799).** The age used to be read
/// as `(try? …isTeen) ?? false`, so a dropped connection told a 14-year-old
/// "Your account is 18 or over, so they don't apply" and took the links to
/// their protections away. Until the age is known, nothing age-dependent is
/// drawn — no header, no footer, no protections — and a failed read shows a
/// failed row with retry. Hiding beats guessing either way: "teen" would
/// misstate an adult's account just as surely, and this page changes nothing
/// by itself, so showing nothing costs only a tap on Retry.
///
/// **Parental Supervision (#417, backend #670).** Under the protections, the
/// viewer's supervisions in both roles — who supervises them, the teens they
/// supervise — each opening its detail (End Supervision), then Invite a
/// Parent / Invite a Teen (the viewer's side follows the age) and Enter an
/// Invite Code. A teen always sees who supervises them here. A deployment
/// that serves none of it keeps "Not Available Yet".
final class FamilyAndTeensViewController: UIViewController, SettingsSectionLinking {
    enum Section: Hashable {
        case protections, supervision
    }

    /// One protection: what it is, what it does, and the page that changes it.
    struct Protection: Hashable {
        let title: String
        let detail: String
        let symbol: String
        let section: SettingsSection?
    }

    enum Item: Hashable {
        case protection(Protection)
        /// Not served by this deployment.
        case supervision
        case loading
        case failed
        /// One of the viewer's supervisions, either role.
        case link(Supervision)
        case supervisionLoading
        case supervisionFailed
        case invite
        case enterCode
    }

    static let failedText = "Couldn't load your account's age. Tap to try again."

    var openSection: ((SettingsSection) -> Void)?
    /// The account's age bracket, read on arrival and from the failed row;
    /// its closure throws when the account can't be read.
    private let ageCheck: TeenAgeCheck
    private let screenTime: ScreenTimeStore
    private var age: Loadable<Bool> { ageCheck.age }
    /// True or false once known; nil while loading or after a failed read.
    private var teen: Bool? { age.content }
    /// The viewer's supervisions; nil when the deployment serves none.
    let supervisionList: SupervisionListModel?
    private let imagePipeline: ImagePipeline?
    private let router: (any Router)?
    /// The supervision a notification asked for (#1106): opened once the
    /// list has it and the page is at rest, then forgotten.
    var pendingSupervisionAccountID: String?
    #if DEBUG
    /// `-supervision-open` runs once per screen, not on every appearance.
    fileprivate var didOpenSupervisionForQA = false
    #endif
    private var collectionView: UICollectionView!
    private(set) var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        isTeen: @escaping () async throws -> Bool,
        screenTime: ScreenTimeStore = .standard,
        supervision: (any SupervisionManaging)? = nil,
        imagePipeline: ImagePipeline? = nil,
        router: (any Router)? = nil
    ) {
        ageCheck = TeenAgeCheck(isTeen: isTeen)
        self.screenTime = screenTime
        supervisionList = supervision.map(SupervisionListModel.init(manager:))
        self.imagePipeline = imagePipeline
        self.router = router
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.familyAndTeens.title
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
        supervisionList?.onChange = { [weak self] in
            self?.applySnapshot()
            self?.openPendingSupervision()
        }
        applySnapshot()
        readAge()
    }

    /// Reads the supervisions once the age is known: the rows that follow
    /// (which invite, which side) depend on it.
    private func loadSupervisions() {
        guard let supervisionList, teen != nil else { return }
        Task { await supervisionList.load() }
    }

    /// Reads the age; a retry that fails again keeps the failed row and says
    /// so. A tap while a read runs sends nothing (`TeenAgeCheck`).
    private func readAge() {
        let isRetry = age.isFailed
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await ageCheck.read()
            applySnapshot()
            if succeeded { loadSupervisions() }
            if isRetry, !succeeded {
                // The failed row’s words: "You’re offline" when that is why (#794).
                Feedback.failure(
                    FailureCopy.title(for: ageCheck.failure, fallback: "Couldn't load your account's age"), from: self
                )
            }
        }
    }

    /// The age as the page draws it: known, or failed — a read that throws
    /// is never folded into "adult". Pure, so the rule is pinned by tests.
    static func readAge(_ isTeen: () async throws -> Bool) async -> Loadable<Bool> {
        do {
            return .content(try await isTeen())
        } catch {
            return .failed(message: FailureCopy.row(for: error, fallback: failedText))
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The daily limit may have changed in Time Management.
        if teen != nil { applySnapshot() }
        // Back from an invite, the other side may have accepted it; back
        // from a detail, it may have ended. The first read is `readAge`'s.
        if case .loaded = supervisionList?.phase { loadSupervisions() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        openSupervisionForQA()
        #endif
        openPendingSupervision()
    }

    // MARK: - Copy

    static func protections(dailyLimitMinutes: Int?) -> [Protection] {
        [
            Protection(title: "Private Account", detail: "The profile starts private: only approved followers see posts.",
                       symbol: "lock", section: .privacy),
            Protection(title: "Messages and Mentions", detail: "Only followers can send messages or mention you.",
                       symbol: "bubble.left.and.bubble.right", section: .privacy),
            Protection(title: "Location", detail: "Hidden on the map. When shared, only mutual friends see the city.",
                       symbol: "location.slash", section: .privacy),
            Protection(title: "Sensitive Content", detail: "Always Less until 18.",
                       symbol: "eye.slash", section: .whatYouSee),
            Protection(title: "Daily Limit", detail: dailyLimitMinutes.map { "A reminder after \($0) minutes a day on this iPhone." }
                       ?? "Off on this iPhone. It starts at \(TeenProtections.defaultDailyLimitMinutes) minutes.",
                       symbol: "hourglass", section: .activity),
            Protection(title: "Quiet Hours", detail: "No notifications from 22:00 to 07:00.",
                       symbol: "moon", section: .notifications),
            Protection(title: "Purchases", detail: "Off until 18: gems can't be bought or spent.",
                       symbol: "cart.badge.minus", section: nil),
        ]
    }

    static func header(_ section: Section, teen: Bool) -> String {
        switch section {
        case .protections: teen ? "Teen Protections" : "For Accounts Aged 13 to 17"
        case .supervision: "Parental Supervision"
        }
    }

    static func footer(_ section: Section, teen: Bool) -> String {
        switch section {
        case .protections:
            teen
                ? "Your account is 13 to 17, so these started on. Tap one to change it. Sensitive Content and purchases stay as they are until you turn 18."
                : "An account aged 13 to 17 starts with these on, from the date of birth given at sign-up. Your account is 18 or over, so they don't apply."
        case .supervision:
            "Linking a parent's account to see activity and set limits isn't available yet."
        }
    }

    /// The supervision section's footer, from what the list holds.
    private func supervisionFooter(teen: Bool) -> String {
        guard let supervisionList else { return Self.footer(.supervision, teen: teen) }
        return SupervisionCopy.footer(
            teen: teen, linked: !supervisionList.supervisions.isEmpty, full: teen && !supervisionList.canInviteSupervisor
        )
    }

    /// The supervision rows: the links (supervisors first: what a teen most
    /// needs to see), then the ways to make one. A teen with two supervisors
    /// is offered no invite, which no one could accept (ACC-3003).
    static func supervisionItems(_ phase: SupervisionListModel.Phase, teen: Bool) -> [Item] {
        switch phase {
        case .loading: return [.supervisionLoading]
        case .failed: return [.supervisionFailed]
        case .loaded(let links):
            let supervisors = links.filter { $0.otherRole == .supervisor }
            let teens = links.filter { $0.otherRole == .teen }
            let canInvite = !teen || supervisors.count < SupervisionListModel.maxSupervisors
            var items: [Item] = (supervisors + teens).map(Item.link)
            if canInvite { items.append(.invite) }
            items.append(.enterCode)
            return items
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            // Only a failed row is tapped to retry: VoiceOver says so (#799).
            cell.accessibilityTraits.remove(.button)
            var content = UIListContentConfiguration.subtitleCell()
            content.secondaryTextProperties.color = .secondaryLabel
            switch item {
            case .protection(let protection):
                content.text = protection.title
                content.secondaryText = protection.detail
                content.image = UIImage(systemName: protection.symbol)
                content.imageProperties.tintColor = .label
                if teen == true, protection.section != nil, openSection != nil { cell.accessories = [.disclosureIndicator()] }
            case .supervision:
                content = .cell()
                content.text = "Not Available Yet"
                content.textProperties.color = .secondaryLabel
            case .loading, .supervisionLoading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .supervisionFailed:
                content = .cell()
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(for: supervisionList?.failure, fallback: SupervisionCopy.failedRow)
                content.textProperties.color = .secondaryLabel
                cell.accessibilityTraits.insert(.button)
            case .invite:
                content = .cell()
                content.text = SupervisionCopy.inviteRowTitle(teen: teen == true)
                content.image = UIImage(systemName: "person.badge.plus")
                content.textProperties.color = .tintColor
                cell.accessibilityTraits.insert(.button)
            case .enterCode:
                content = .cell()
                content.text = SupervisionCopy.enterCodeTitle
                content.image = UIImage(systemName: "keyboard")
                content.textProperties.color = .tintColor
                cell.accessibilityTraits.insert(.button)
            case .link:
                break
            case .failed:
                content = .cell()
                // The read's words: "You’re offline…" when that is why (#794).
                if case .failed(let message) = age {
                    content.text = message
                } else {
                    content.text = Self.failedText
                }
                content.textProperties.color = .secondaryLabel
                cell.accessibilityTraits.insert(.button)
            }
            cell.contentConfiguration = content
        }
        let linkRegistration = UICollectionView.CellRegistration<PersonListCell, Supervision> { [weak self] cell, _, link in
            let profile = link.primary
            cell.configure(with: PersonRowContent(
                displayName: link.name,
                // The side, beside the handle: a teen reads "Supervises you".
                handle: "\(link.handleText) · \(SupervisionCopy.roleText(link))",
                monogram: MonogramAvatarView.monogram(name: profile?.displayName ?? "", handle: profile?.handle ?? link.name)
            ))
            cell.accessories.append(.disclosureIndicator())
            cell.avatar.setPicture(profile?.avatarURL, pipeline: self?.imagePipeline)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            if case .link(let link) = item {
                return collectionView.dequeueConfiguredReusableCell(using: linkRegistration, for: indexPath, item: link)
            }
            return collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.header()
            // No age-dependent wording until the age is known (#799).
            content.text = self.teen.flatMap { teen in
                self.dataSource.sectionIdentifier(for: indexPath.section).map { Self.header($0, teen: teen) }
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = self.teen.flatMap { teen in
                self.dataSource.sectionIdentifier(for: indexPath.section).map { section in
                    section == .supervision ? self.supervisionFooter(teen: teen) : Self.footer(section, teen: teen)
                }
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
        snapshot.appendSections([.protections])
        switch age {
        case .loading, .empty:
            snapshot.appendItems([.loading], toSection: .protections)
        case .failed:
            snapshot.appendItems([.failed], toSection: .protections)
        case .content(let teen):
            let protections = Self.protections(dailyLimitMinutes: screenTime.settings.dailyLimitMinutes)
            snapshot.appendItems(protections.map(Item.protection), toSection: .protections)
            // A supervision in place leads the page: a teen sees who
            // supervises them first, not seven rows down.
            let linked = !(supervisionList?.supervisions.isEmpty ?? true)
            if linked {
                snapshot.insertSections([.supervision], beforeSection: .protections)
            } else {
                snapshot.appendSections([.supervision])
            }
            let supervision: [Item] = supervisionList.map { Self.supervisionItems($0.phase, teen: teen) } ?? [.supervision]
            snapshot.appendItems(supervision, toSection: .supervision)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension FamilyAndTeensViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed, .supervisionFailed, .link, .invite, .enterCode: return true
        case .protection(let protection): return teen == true && protection.section != nil && openSection != nil
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed: readAge()
        case .supervisionFailed: loadSupervisions()
        case .link(let link): openSupervision(link)
        case .invite: openInvite()
        case .enterCode: openAccept()
        case .protection(let protection):
            guard teen == true, let section = protection.section else { return }
            openSection?(section)
        default: break
        }
    }
}

// MARK: - Parental Supervision (#417)

extension FamilyAndTeensViewController {
    /// The viewer's own side: a teen invites a parent, anyone else a teen
    /// (the server refuses an age that fits neither, ACC-3002).
    private var viewerRole: SupervisionRole? {
        teen.map { $0 ? .teen : .supervisor }
    }

    func openInvite() {
        guard let supervisionList, let viewerRole else { return }
        let model = SupervisionInviteModel(manager: supervisionList.manager, role: viewerRole)
        navigationController?.pushViewController(SupervisionInviteViewController(model: model), animated: true)
    }

    func openAccept(code: String = "") {
        guard let supervisionList else { return }
        let model = SupervisionAcceptModel(manager: supervisionList.manager, code: code, viewerRole: viewerRole)
        let accept = SupervisionAcceptViewController(model: model) { [weak self] accept, link in
            self?.supervisionList?.accepted(link)
            accept.navigationController?.popViewController(animated: true)
            if let self { Feedback.success(SupervisionCopy.linkedToast(link), from: self) }
        }
        navigationController?.pushViewController(accept, animated: true)
    }

    func openSupervision(_ link: Supervision) {
        guard let supervisionList else { return }
        // The overview and limits ride on the same account service (#417
        // parts 2 and 3); a manager without them leaves the page to pairing.
        let detail = SupervisionDetailViewController(
            supervision: link, list: supervisionList, overviewing: supervisionList.manager as? any SupervisionOverviewing,
            imagePipeline: imagePipeline, router: router
        ) { [weak self] detail, ended, wasGone in
            detail.navigationController?.popViewController(animated: true)
            guard let self else { return }
            if wasGone {
                // The other side ended it first, or the teen turned 18.
                Feedback.warning(SupervisionCopy.failureText(SupervisionError.notFound, teen: teen, fallback: ""), from: self)
            } else {
                Feedback.success(SupervisionCopy.endedToast(ended), from: self)
            }
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    /// Opens the link a notification asked for, once the list is in and the
    /// page is the top screen at rest; a link that has ended leaves the page
    /// as it is.
    func openPendingSupervision() {
        guard let pending = pendingSupervisionAccountID, let supervisionList,
              case .loaded(let links) = supervisionList.phase else { return }
        guard view.window != nil, let navigation = navigationController, navigation.topViewController === self else { return }
        // Still sliding in (the list can land first, and `viewDidAppear`
        // runs inside the push's completion): wait for the stack to settle,
        // or UIKit drops the push.
        guard navigation.transitionCoordinator == nil else {
            navigation.whenAtRest { [weak self] in self?.openPendingSupervision() }
            return
        }
        pendingSupervisionAccountID = nil
        guard let link = links.first(where: { $0.otherAccountID == pending }) else { return }
        openSupervision(link)
    }

    #if DEBUG
    /// `-supervision-open invite|accept|first|limits`: pushes that screen
    /// (`limits`: the first link's limits editor) once the
    /// age and the list are in — the rows take no simulated touch. With
    /// `-open-settings familyAndTeens`.
    private func openSupervisionForQA() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !didOpenSupervisionForQA, let index = arguments.firstIndex(of: "-supervision-open"),
              index + 1 < arguments.count else { return }
        didOpenSupervisionForQA = true
        let target = arguments[index + 1]
        QAWait.until("supervision-open", { [weak self] in
            guard let self, let navigation = navigationController else { return false }
            guard case .loaded = supervisionList?.phase else { return false }
            return navigation.topViewController === self && navigation.transitionCoordinator == nil
        }) { [weak self] in
            guard let self else { return }
            switch target {
            case "invite": openInvite()
            case "accept": openAccept()
            case "first", "limits":
                guard let first = supervisionList?.supervisions.first else {
                    return QAWait.fail("supervision-open", "no supervision to open")
                }
                openSupervision(first)
                guard target == "limits" else { return }
                // The editor needs the overview in, and the detail at rest.
                QAWait.until("supervision-open limits", { [weak self] in
                    guard let navigation = self?.navigationController,
                          let detail = navigation.topViewController as? SupervisionDetailViewController else { return false }
                    return detail.overview?.overview != nil && navigation.transitionCoordinator == nil
                }) { [weak self] in
                    (self?.navigationController?.topViewController as? SupervisionDetailViewController)?.openLimitsEditor()
                }
            default:
                QAWait.fail("supervision-open", "unknown target \(target)")
            }
        }
    }
    #endif
}
