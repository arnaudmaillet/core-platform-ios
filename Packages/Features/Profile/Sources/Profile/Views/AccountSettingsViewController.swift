import DesignSystem
import UIKit

/// Settings → Account: the account-wide identity rows, pushed from the root
/// `SettingsViewController`. A native inset-grouped list following the same
/// push-to-child pattern as Edit Profile: account rows show
/// `[Label]  [Value] ›` and push a focused editor.
///
/// Contract reality (see `AccountRepository`): email/phone are read-only —
/// `account.v1` has no change RPC — so their editors are honest placeholders
/// (Save reports "not available yet").
final class AccountSettingsViewController: UIViewController {
    private let account: any AccountProviding
    /// Backs Delete Account. Nil hides the row rather than offering a
    /// deletion that cannot be sent.
    private let lifecycle: (any AccountLifecycleManaging)?
    private let onAccountDeleted: () -> Void

    private var details: AccountDetails?
    private var isShowingSkeleton = false
    /// A notice owed to the viewer once this list is back on screen — see
    /// `reportReadOnly`.
    private var pendingNotice: String?

    private enum Section: Int, CaseIterable {
        case accountInfo, management

        var title: String? {
            switch self {
            case .accountInfo: "Account Information"
            case .management: "Account Management"
            }
        }
    }

    private enum Row: Hashable {
        case email, phone
        case deactivate, delete, dataExport
    }

    private enum Item: Hashable {
        case row(Row)
        /// Shimmer stand-ins for the account-info values while they load.
        case skeleton(Int)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        account: any AccountProviding,
        lifecycle: (any AccountLifecycleManaging)? = nil,
        onAccountDeleted: @escaping () -> Void = {}
    ) {
        self.account = account
        self.lifecycle = lifecycle
        self.onAccountDeleted = onAccountDeleted
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SettingsSection.account.title
        navigationItem.largeTitleDisplayMode = .never
        configureCollectionView()
        configureDataSource()
        // Only the account-info values wait on the network; the rest is static.
        isShowingSkeleton = true
        dataSource.apply(makeSnapshot(loaded: false), animatingDifferences: false)
        loadAccount()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
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
        let rowRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            self?.configure(cell, for: row)
        }
        let skeletonRegistration = UICollectionView.CellRegistration<AccountSkeletonRowCell, Int> { cell, _, index in
            cell.configure(index: index)
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .row(let row):
                return collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: row)
            case .skeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: skeletonRegistration, for: indexPath, item: index)
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = section.title
            header.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    // MARK: - Snapshot

    private func makeSnapshot(loaded: Bool) -> NSDiffableDataSourceSnapshot<Section, Item> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.accountInfo, .management])
        if loaded {
            snapshot.appendItems([.row(.email), .row(.phone)], toSection: .accountInfo)
        } else {
            snapshot.appendItems([.skeleton(0), .skeleton(1)], toSection: .accountInfo)
        }
        snapshot.appendItems([.row(.dataExport), .row(.deactivate)], toSection: .management)
        if lifecycle != nil {
            snapshot.appendItems([.row(.delete)], toSection: .management)
        }
        return snapshot
    }

    private func loadAccount() {
        Task { [weak self] in
            guard let self else { return }
            self.details = try? await self.account.currentAccount()
            self.reveal()
        }
    }

    private func reveal() {
        guard isShowingSkeleton else { return }
        isShowingSkeleton = false
        // Only the account-info rows change; cross-dissolve so the shimmer melts
        // into the loaded values rather than snapping.
        UIView.transition(with: collectionView, duration: 0.3, options: .transitionCrossDissolve) {
            self.dataSource.apply(self.makeSnapshot(loaded: true), animatingDifferences: false)
        }
    }

    // MARK: - Row rendering

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        switch row {
        case .email:
            valueCell(cell, label: "Email", value: details?.email, verified: details?.emailVerified)
        case .phone:
            valueCell(cell, label: "Phone", value: details?.phone.isEmpty == false ? details?.phone : "Not set", verified: details?.phoneVerified)
        case .deactivate:
            actionCell(cell, label: "Deactivate Account", destructive: true)
        case .delete:
            actionCell(cell, label: "Delete Account", destructive: true)
            cell.accessories = [.disclosureIndicator()]
        case .dataExport:
            actionCell(cell, label: "Request Data Export", destructive: false)
        }
    }

    /// `[Label]  [value] (✓) ›` — a value row that pushes an editor.
    private func valueCell(_ cell: UICollectionViewListCell, label: String, value: String?, verified: Bool?) {
        var content = UIListContentConfiguration.valueCell()
        content.text = label
        content.secondaryText = value
        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = [.disclosureIndicator()]
        if verified == true {
            let check = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
            check.tintColor = .systemGreen
            accessories.insert(
                .customView(configuration: .init(customView: check, placement: .trailing(displayed: .always))),
                at: 0
            )
        }
        cell.accessories = accessories
    }

    /// A tappable action row (no chevron); `destructive` tints the label red.
    private func actionCell(_ cell: UICollectionViewListCell, label: String, destructive: Bool) {
        var content = UIListContentConfiguration.cell()
        content.text = label
        if destructive {
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        cell.accessories = []
    }

    // MARK: - Row actions

    private func handle(_ row: Row) {
        switch row {
        case .email:
            pushEmailEditor()
        case .phone:
            pushPhoneEditor()
        case .deactivate:
            // Not a fake confirmation: a deactivated account cannot sign back
            // in yet (#385), so the row only says so.
            presentInfo("Deactivating isn't available yet: a deactivated account couldn't log back in. You can delete your account instead.")
        case .delete:
            guard let lifecycle else { return }
            push(DeleteAccountViewController(
                viewModel: DeleteAccountViewModel(lifecycle: lifecycle),
                onAccountDeleted: onAccountDeleted
            ))
        case .dataExport:
            confirmComingSoonAction(title: "Request Data Export?", confirm: "Request Export", message: "Data export isn't available yet.")
        }
    }

    private func pushEmailEditor() {
        push(EditFieldViewController(config: .init(
            title: "Email",
            initialValue: details?.email ?? "",
            placeholder: "you@example.com",
            characterLimit: 254,
            keyboardType: .emailAddress,
            autocapitalization: .none,
            autocorrection: .no,
            helperText: "The address you use to sign in.",
            validate: Self.validateEmail,
            onSave: { [weak self] _ in self?.reportReadOnly("Changing your email isn't available yet.") }
        )))
    }

    private func pushPhoneEditor() {
        push(EditFieldViewController(config: .init(
            title: "Phone",
            initialValue: details?.phone ?? "",
            placeholder: "+1 (555) 000-0000",
            characterLimit: 32,
            keyboardType: .phonePad,
            autocapitalization: .none,
            autocorrection: .no,
            helperText: "Used for account recovery and verification.",
            onSave: { [weak self] _ in self?.reportReadOnly("Changing your phone number isn't available yet.") }
        )))
    }

    /// The child editor pops itself on Save; report the read-only reality on the
    /// settings list once the pop has landed.
    ///
    /// ⚠️ **"LANDED" IS `viewDidAppear`, NOT THE NEXT RUN-LOOP TURN.** The
    /// editor calls `onSave` and then starts its pop, so one hop later the pop
    /// had only just begun: the alert came up over a screen still sliding
    /// (~350 ms) with the keyboard still leaving. Held until this list is back,
    /// on the pop's own completion, however long it takes.
    private func reportReadOnly(_ message: String) {
        pendingNotice = message
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let notice = pendingNotice {
            pendingNotice = nil
            presentInfo(notice)
        }
    }

    private func confirmComingSoonAction(title: String, confirm: String, message: String) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: confirm, style: .destructive) { [weak self] _ in
            self?.presentInfo(message)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentSheet(sheet)
    }

    // MARK: - Helpers

    private func push(_ viewController: UIViewController) {
        navigationController?.pushViewController(viewController, animated: true)
    }

    /// Anchors an action sheet to a sensible source on iPad (where `.actionSheet`
    /// is presented as a popover and requires one).
    private func presentSheet(_ sheet: UIAlertController) {
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    private func presentInfo(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private static func validateEmail(_ value: String) -> String? {
        // Lightweight, non-authoritative: one @, a dot in the domain, no spaces.
        guard !value.isEmpty else { return "Email can't be empty." }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !value.contains(" ") else {
            return "Enter a valid email address."
        }
        return nil
    }
}

// MARK: - Selection

extension AccountSettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .row(let row) = dataSource.itemIdentifier(for: indexPath) else { return }
        handle(row)
    }
}

// MARK: - Skeleton row cell

/// Shimmer stand-in for a value row: a short label bone leading, a value bone
/// trailing. Keeps the grouped background so it reads like the real rows.
private final class AccountSkeletonRowCell: UICollectionViewListCell {
    private let labelBone = SkeletonBoneView(rounding: .capsule)
    private let valueBone = SkeletonBoneView(rounding: .capsule)
    private lazy var valueWidth = valueBone.widthAnchor.constraint(equalToConstant: 120)
    private static let valueWidths: [CGFloat] = [150, 120]

    override init(frame: CGRect) {
        super.init(frame: frame)
        labelBone.translatesAutoresizingMaskIntoConstraints = false
        valueBone.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labelBone)
        contentView.addSubview(valueBone)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            labelBone.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            labelBone.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            labelBone.widthAnchor.constraint(equalToConstant: 56),
            labelBone.heightAnchor.constraint(equalToConstant: 12),
            valueBone.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            valueBone.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueWidth,
            valueBone.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(index: Int) {
        valueWidth.constant = Self.valueWidths[index % Self.valueWidths.count]
    }
}
