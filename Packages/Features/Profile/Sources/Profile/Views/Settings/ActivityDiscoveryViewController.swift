import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Privacy → Activity and Discovery (#406, #412): activity status
/// and read receipts (chat withholds them, backend #727), the ways people find
/// this profile (backend #726), and its QR code and shared links, which the
/// owner can turn off or reset (backend #661). Switches save at once and snap
/// back if the server refuses.
final class ActivityDiscoveryViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(ActivityDiscoverySettings)
        case failed
    }

    enum Section: Hashable {
        case activity, discovery, links, contacts
    }

    private enum Item: Hashable {
        case toggle(ActivityDiscoverySettings.Switch)
        case resetLink
        case findContacts
        case loading
        case failed
        /// Past 10 s (#1770): a row a tap retries.
        case takingLonger
    }

    static let discoverySwitches: [ActivityDiscoverySettings.Switch] = [
        .findableInSearch, .findableByPhone, .findableByEmail, .inSuggestions,
    ]

    private let manager: any ActivityDiscoveryManaging
    private let shareLinks: (any ShareLinkManaging)?
    /// Find Friends from Contacts (#412); nil hides the row.
    private let makeContactFriends: (() -> UIViewController)?
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    private var saving: Set<ActivityDiscoverySettings.Switch> = []
    private var resetting = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        manager: any ActivityDiscoveryManaging,
        shareLinks: (any ShareLinkManaging)? = nil,
        makeContactFriends: (() -> UIViewController)? = nil
    ) {
        self.manager = manager
        self.shareLinks = shareLinks
        self.makeContactFriends = makeContactFriends
        super.init(nibName: nil, bundle: nil)
        title = "Activity and Discovery"
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
                phase = .loaded(try await manager.activityDiscoverySettings())
            } catch {
                loadFailure = NetworkFailure.of(error)
                phase = .failed
            }
        }
    }

    // MARK: - Copy

    static func title(_ key: ActivityDiscoverySettings.Switch) -> String {
        switch key {
        case .activityStatus: "Activity Status"
        case .readReceipts: "Read Receipts"
        case .findableInSearch: "Show Up in Search"
        case .findableByPhone: "Find Me by Phone Number"
        case .findableByEmail: "Find Me by Email"
        case .reachableByLink: "QR Code and Shared Links"
        case .inSuggestions: "Suggest My Account to Others"
        }
    }

    static let resetTitle = "Reset QR Code and Link"
    static let findContactsTitle = "Find Friends from Contacts"

    static func symbol(_ key: ActivityDiscoverySettings.Switch) -> String {
        switch key {
        case .activityStatus: "circle.fill"
        case .readReceipts: "checkmark.message"
        case .findableInSearch: "magnifyingglass"
        case .findableByPhone: "phone"
        case .findableByEmail: "envelope"
        case .reachableByLink: "qrcode"
        case .inSuggestions: "person.2"
        }
    }

    static func header(_ section: Section) -> String? {
        switch section {
        case .activity: "In Messages"
        case .discovery: "Finding You"
        case .links: "QR Code and Links"
        case .contacts: "Your Contacts"
        }
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .activity:
            "When Activity Status is off, people in your conversations don't see when you're active. When Read Receipts is off, they don't see when you've read their messages. Applies to this profile."
        case .discovery:
            "Turn these off to keep your profile out of search, out of contact matches for people who have your phone number or email, and out of suggestions. People can still reach it through your posts and your followers."
        case .links:
            "When this is off, your QR code and the links you've shared don't open your profile. Resetting gives you a new code and link; the old ones stop working right away."
        case .contacts:
            "See which of your contacts are here. Only codes made from their email addresses and phone numbers are checked, and nothing is stored."
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.cell()
            switch item {
            case .toggle(let key):
                content.text = Self.title(key)
                content.image = UIImage(systemName: Self.symbol(key))
                content.imageProperties.tintColor = key == .activityStatus ? .systemGreen : .label
                let toggle = UISwitch()
                if case .loaded(let settings) = phase { toggle.isOn = settings[key] }
                toggle.isEnabled = !saving.contains(key)
                toggle.accessibilityLabel = Self.title(key)
                toggle.addAction(UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.set(key, to: toggle.isOn)
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
            case .resetLink:
                content.text = Self.resetTitle
                content.textProperties.color = resetting ? .secondaryLabel : .systemRed
                if resetting {
                    let spinner = AppLoaderView(size: .medium)
                    spinner.startAnimating()
                    cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing(displayed: .always)))]
                }
            case .findContacts:
                content.text = Self.findContactsTitle
                content.image = UIImage(systemName: "person.crop.circle.badge.plus")
                content.imageProperties.tintColor = .label
                cell.accessories = [.disclosureIndicator()]
            case .loading:
                cell.contentConfiguration = SkeletonRowConfiguration(sample: "A row of this list")
                cell.accessories = []
                return
            case .takingLonger:
                content.text = TakingLongerCopy.row
                content.textProperties.color = .secondaryLabel
            case .failed:
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: loadFailure, fallback: "Couldn't load these settings. Tap to try again."
                )
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.footer)
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
        switch phase {
        case .loading:
            snapshot.appendSections([.activity])
            // The kit's timing (#1770): nothing for its delay, the bones,
            // "taking longer" past 10 s.
            switch loadingGate.loading() {
            case .bones: snapshot.appendItems([.loading], toSection: .activity)
            case .takingLonger: snapshot.appendItems([.takingLonger], toSection: .activity)
            case .nothing: break
            }
        case .failed:
            snapshot.appendSections([.activity])
            snapshot.appendItems([.failed], toSection: .activity)
        case .loaded:
            snapshot.appendSections([.activity, .discovery, .links])
            snapshot.appendItems([.toggle(.activityStatus), .toggle(.readReceipts)], toSection: .activity)
            snapshot.appendItems(Self.discoverySwitches.map(Item.toggle), toSection: .discovery)
            snapshot.appendItems([.toggle(.reachableByLink)] + (shareLinks == nil ? [] : [.resetLink]), toSection: .links)
            if makeContactFriends != nil {
                snapshot.appendSections([.contacts])
                snapshot.appendItems([.findContacts], toSection: .contacts)
            }
            snapshot.reconfigureItems(ActivityDiscoverySettings.Switch.allCases.map(Item.toggle) + (shareLinks == nil ? [] : [.resetLink]))
        }
        let animated = false
        if case .loading = phase {
            dataSource.apply(snapshot, animatingDifferences: animated)
        } else {
            // The answer waits out the bones' minimum (#1770).
            loadingGate.landed { [weak self] in self?.dataSource.apply(snapshot, animatingDifferences: animated) }
        }
    }

    /// The settings' loading on the kit's timing (#1770). Injectable so a
    /// test steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var loadingGate: ListSkeletonGate = {
        let gate = ListSkeletonGate(clock: skeletonClock)
        gate.onChange = { [weak self] in self?.applySnapshot() }
        return gate
    }()

    /// Not optimistic: the switch disables while saving, then shows what
    /// the server holds.
    private func set(_ key: ActivityDiscoverySettings.Switch, to isOn: Bool) {
        guard case .loaded(var settings) = phase, !saving.contains(key) else { return }
        saving.insert(key)
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.setActivityDiscovery(key, to: isOn)
                settings[key] = isOn
                saving.remove(key)
                phase = .loaded(settings)
            } catch {
                saving.remove(key)
                applySnapshot()
                // A supervisor's floor holds it (PRF-5006, #417): say who.
                let message = SupervisionLock.message(for: error, fallback: "Couldn't change \(Self.title(key)). Try again.")
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    /// Asks first: the codes people already scanned or saved stop working.
    private func confirmReset() {
        guard shareLinks != nil, !resetting else { return }
        let sheet = UIAlertController(
            title: "Reset your QR code and link?",
            message: "Your current QR code and the links you've shared will stop opening your profile. You'll get a new code and link.",
            preferredStyle: .alert
        )
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in self?.reset() })
        present(sheet, animated: true)
    }

    private func reset() {
        guard let shareLinks else { return }
        resetting = true
        applySnapshot()
        Task { [weak self] in
            do {
                _ = try await shareLinks.rotateShareToken()
                guard let self else { return }
                resetting = false
                applySnapshot()
                Feedback.success("New QR code and link ready", symbol: "qrcode", from: self)
            } catch {
                guard let self else { return }
                resetting = false
                applySnapshot()
                let alert = UIAlertController(title: nil, message: "Couldn't reset your QR code and link. Try again.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}

extension ActivityDiscoveryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed, .takingLonger: true
        case .resetLink: !resetting
        case .findContacts: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed: load()
        case .takingLonger:
            loadingGate.retry()
            load()
        case .resetLink: confirmReset()
        case .findContacts:
            if let screen = makeContactFriends?() { navigationController?.pushViewController(screen, animated: true) }
        default: break
        }
    }
}
