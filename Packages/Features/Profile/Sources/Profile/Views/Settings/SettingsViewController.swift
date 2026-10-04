import CoreModels
import DesignSystem
import ProfileInterface
import UIKit

/// Settings, pushed from the own profile's gear: the sections of
/// `SettingsCatalog` grouped by scope, then Switch Profile and Log Out.
///
/// ## Why the scope is on screen
///
/// One account owns several profiles. A toggle under "Profile · @maya" changes
/// only @maya; one under "Account" follows every profile. Saying so in the
/// section header and footer is the whole difference between a privacy
/// setting the viewer understands and one they believe applies to the profile
/// they switched to a minute ago. The profile header follows the switcher
/// through `.activeProfileDidChange`, whichever surface made the switch.
///
/// A section whose rows are not built yet pushes `SettingsComingSoonViewController`
/// (the factory returns nil for it), never a screen of controls that do nothing.
final class SettingsViewController: UIViewController {
    private enum Section: Hashable {
        case scope(SettingsScope)
        case session
    }

    private enum Item: Hashable {
        case section(SettingsSection)
        case switchProfile
        case logOut
        case signIn
    }

    private let switching: (any ProfileSwitching)?
    private let switcher: ProfileSwitcherMenuFactory?
    private let makeDestination: (SettingsSection) -> UIViewController?
    private let onLogout: () -> Void
    /// Set for a guest (guest mode): only what works without an account — the
    /// app-wide section — and "Log in or sign up" where Log Out would be.
    private let onSignIn: (() -> Void)?

    /// "@handle" of the active profile once known; the header reads "Profile"
    /// until then rather than guessing.
    private var activeHandle: String?
    /// Offered only when the account has another profile to switch to.
    private var canSwitchProfile = false

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        switching: (any ProfileSwitching)?,
        switcher: ProfileSwitcherMenuFactory?,
        makeDestination: @escaping (SettingsSection) -> UIViewController?,
        onLogout: @escaping () -> Void,
        onSignIn: (() -> Void)? = nil
    ) {
        self.switching = switching
        self.switcher = switcher
        self.makeDestination = makeDestination
        self.onLogout = onLogout
        self.onSignIn = onSignIn
        super.init(nibName: nil, bundle: nil)
        // Settings is somewhere you go and come back from, not a fifth tab.
        // Declared here rather than at the push site so it holds wherever this
        // screen is pushed from.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        configureCollectionView()
        configureDataSource()
        applySnapshot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeProfileDidChange(_:)),
            name: .activeProfileDidChange, object: nil
        )
        loadProfileScope()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        collectionView.prefersClearTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let sectionRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SettingsSection> { cell, _, section in
            var content = UIListContentConfiguration.cell()
            content.text = section.title
            content.image = UIImage(systemName: section.symbolName)
            content.imageProperties.tintColor = .label
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let switchRegistration = UICollectionView.CellRegistration<SettingsMenuButtonCell, Item> { [weak self] cell, _, _ in
            cell.configure(title: "Switch Profile", menu: self?.makeSwitcherMenu())
        }
        let logOutRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Log Out"
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            cell.accessories = []
        }
        let signInRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Log in or sign up"
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessories = []
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .section(let section):
                collectionView.dequeueConfiguredReusableCell(using: sectionRegistration, for: indexPath, item: section)
            case .switchProfile:
                collectionView.dequeueConfiguredReusableCell(using: switchRegistration, for: indexPath, item: item)
            case .logOut:
                collectionView.dequeueConfiguredReusableCell(using: logOutRegistration, for: indexPath, item: item)
            case .signIn:
                collectionView.dequeueConfiguredReusableCell(using: signInRegistration, for: indexPath, item: item)
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.headerText(at: indexPath.section)
            header.contentConfiguration = content
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] footer, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText(at: indexPath.section)
            footer.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let scopes = Self.scopes(isGuest: onSignIn != nil)
        for scope in scopes {
            snapshot.appendSections([.scope(scope)])
            snapshot.appendItems(SettingsSection.sections(in: scope).map(Item.section), toSection: .scope(scope))
        }
        snapshot.appendSections([.session])
        if onSignIn != nil {
            snapshot.appendItems([.signIn], toSection: .session)
        } else {
            if canSwitchProfile {
                snapshot.appendItems([.switchProfile], toSection: .session)
            }
            snapshot.appendItems([.logOut], toSection: .session)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func headerText(at index: Int) -> String? {
        guard case .scope(let scope) = dataSource.sectionIdentifier(for: index) else { return nil }
        return Self.headerText(for: scope, activeHandle: activeHandle)
    }

    private func footerText(at index: Int) -> String? {
        guard case .scope(let scope) = dataSource.sectionIdentifier(for: index) else { return nil }
        return Self.footerText(for: scope, activeHandle: activeHandle, isGuest: onSignIn != nil)
    }

    /// What Settings shows. A guest has no account and no profile, so only
    /// what works without one: this device's settings, and help and the
    /// legal pages (#469 on top of the guest mode, #472).
    static func scopes(isGuest: Bool) -> [SettingsScope] {
        isGuest ? [.device, .support] : SettingsScope.allCases
    }

    /// The scope as the viewer reads it. Static and pure so the wording is
    /// pinned by tests rather than by a screenshot.
    static func headerText(for scope: SettingsScope, activeHandle: String?) -> String {
        switch scope {
        case .account: "Account-Wide"
        case .profile: activeHandle.map { "Profile · \($0)" } ?? "Profile"
        case .device: "App and Device"
        case .support: "Support and Legal"
        }
    }

    /// `isGuest`: a guest has no profile, so the device footer can't speak of
    /// "the active profile" to them.
    static func footerText(for scope: SettingsScope, activeHandle: String?, isGuest: Bool = false) -> String? {
        switch scope {
        case .account:
            "Applies to every profile on this account."
        case .profile:
            activeHandle.map { "Applies to \($0) only. Switch profile to change another profile's settings." }
                ?? "Applies to the active profile only."
        case .device:
            isGuest ? "Applies to this iPhone." : "Applies to this iPhone, whichever profile is active."
        case .support:
            nil
        }
    }

    // MARK: - Profile scope

    private func loadProfileScope() {
        guard let switching else { return }
        Task { [weak self] in
            let profiles = (try? await switching.accountProfiles()) ?? []
            let activeID = await switching.activeProfileID()
            await self?.switcher?.reload()
            self?.didLoadProfileScope(profiles: profiles, activeID: activeID)
        }
    }

    private func didLoadProfileScope(profiles: [AccountProfile], activeID: ProfileID?) {
        let active = profiles.first { $0.id == activeID } ?? profiles.first
        activeHandle = active.map { "@\($0.handle)" }
        canSwitchProfile = switcher != nil && profiles.count > 1
        applySnapshot()
        // The headers carry the handle; a snapshot with unchanged items does
        // not re-run their registrations.
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func activeProfileDidChange(_ note: Notification) {
        loadProfileScope()
    }

    private func makeSwitcherMenu() -> UIMenu? {
        // Switch-only: creating a profile belongs to the profile screen.
        switcher?.makeMenu(includesAddProfile: false, onSwitch: {}, onAddProfile: {})
    }

    // MARK: - Actions

    func open(_ section: SettingsSection, animated: Bool = true) {
        let destination = makeDestination(section) ?? SettingsComingSoonViewController(section: section)
        navigationController?.pushViewController(destination, animated: animated)
    }

    private func confirmLogout() {
        let sheet = UIAlertController(
            title: "Are you sure you want to log out?",
            message: nil,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
            self?.onLogout()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad presents an action sheet as a popover, which needs a source.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }
}

// MARK: - Selection

extension SettingsViewController: UICollectionViewDelegate {
    /// ⚠️ The Switch Profile row must not highlight. A highlightable cell
    /// claims the touch for selection and its button's menu never opens.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .switchProfile
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .section(let section):
            open(section)
        case .logOut:
            confirmLogout()
        case .signIn:
            onSignIn?()
        case .switchProfile, nil:
            // The row's own button opens the menu; selection never reaches here.
            break
        }
    }
}

// MARK: - Menu button cell

/// A list row whose whole surface is a `UIButton` showing a menu on tap.
///
/// The button fills the content view rather than riding as an accessory: an
/// accessory button gets no touches unless wrapped in a sized host, and a
/// menu needs the touch to reach the button itself.
private final class SettingsMenuButtonCell: UICollectionViewListCell {
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .leading
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, menu: UIMenu?) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.appFont(forTextStyle: .body)
            return attributes
        }
        button.configuration = configuration
        button.menu = menu
        button.isEnabled = menu != nil
    }
}
