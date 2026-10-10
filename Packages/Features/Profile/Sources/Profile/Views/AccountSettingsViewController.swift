import DesignSystem
import UIKit

/// Settings → Account: the account-wide identity rows, pushed from the root
/// `SettingsViewController`. A native inset-grouped list following the same
/// push-to-child pattern as Edit Profile: account rows show
/// `[Label]  [Value] ›` and push a focused editor.
///
/// Email and phone change through `auth.v1` (#393, backend #651): a code to
/// the new address, behind a step-up (`ChangeContactViewController`). Without
/// a `contactChanger` their editors stay honest placeholders (Save reports
/// "not available yet").
final class AccountSettingsViewController: UIViewController {
    private let account: any AccountProviding
    /// Backs Delete Account. Nil hides the row rather than offering a
    /// deletion that cannot be sent.
    private let lifecycle: (any AccountLifecycleManaging)?
    /// What Delete Account names before the irreversible step (#402).
    private let deletionChecklist: @Sendable () async -> DeletionChecklist?
    private let onAccountDeleted: () -> Void
    private let deactivator: (any AccountDeactivating)?
    private let stepUp: (any CredentialStepUp)?
    /// Changes the email and phone; nil keeps the placeholders.
    private let contactChanger: (any ContactChanging)?
    /// After a deactivation: sign out, the account being asleep until the next
    /// login.
    private let onDeactivated: () -> Void

    /// The account-info rows' state: skeleton, values, or a failed row with
    /// retry — never a default standing in for a failed read (#799).
    private let viewModel: AccountDetailsViewModel
    private var details: AccountDetails? { viewModel.details }
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
        case email, phone, birthDate
        case deactivate, delete, dataExport
    }

    private enum Item: Hashable {
        case row(Row)
        /// Shimmer stand-ins for the account-info values while they load.
        case skeleton(Int)
        /// The account couldn't be read: one row in place of the three
        /// values, tapped to read it again (#799).
        case failed
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        account: any AccountProviding,
        lifecycle: (any AccountLifecycleManaging)? = nil,
        onAccountDeleted: @escaping () -> Void = {},
        deactivator: (any AccountDeactivating)? = nil,
        stepUp: (any CredentialStepUp)? = nil,
        contactChanger: (any ContactChanging)? = nil,
        onDeactivated: @escaping () -> Void = {},
        deletionChecklist: @escaping @Sendable () async -> DeletionChecklist? = { nil }
    ) {
        self.contactChanger = contactChanger
        self.deletionChecklist = deletionChecklist
        self.account = account
        self.viewModel = AccountDetailsViewModel(account: account)
        self.lifecycle = lifecycle
        self.onAccountDeleted = onAccountDeleted
        self.deactivator = deactivator
        self.stepUp = stepUp
        self.onDeactivated = onDeactivated
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
        dataSource.apply(makeSnapshot(for: viewModel.phase), animatingDifferences: false)
        viewModel.onChange = { [weak self] in self?.render() }
        // A first failure speaks through the failed row, so no toast here.
        Task { await viewModel.load() }
    }

    // MARK: - Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // UIKit's soft blur under the bar, like every Settings screen — see
        // `prefersSoftTopEdge`.
        collectionView.prefersSoftTopEdge()
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
        // The failed-row style every Settings screen uses.
        let failedRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.cell()
            // The phase's words: "You’re offline…" when that is why (#794).
            if case .failed(let message) = self?.viewModel.phase {
                content.text = message
            } else {
                content.text = AccountDetailsViewModel.failureMessage
            }
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
            // Tapped to retry: VoiceOver says so.
            cell.accessibilityTraits.insert(.button)
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .row(let row):
                return collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: row)
            case .skeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: skeletonRegistration, for: indexPath, item: index)
            case .failed:
                return collectionView.dequeueConfiguredReusableCell(using: failedRegistration, for: indexPath, item: item)
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

    private static let accountInfoRows: [Item] = [.row(.email), .row(.phone), .row(.birthDate)]

    private func makeSnapshot(for phase: AccountDetailsViewModel.Phase) -> NSDiffableDataSourceSnapshot<Section, Item> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.accountInfo, .management])
        switch phase {
        case .content:
            snapshot.appendItems(Self.accountInfoRows, toSection: .accountInfo)
        case .loading, .empty:
            snapshot.appendItems([.skeleton(0), .skeleton(1), .skeleton(2)], toSection: .accountInfo)
        case .failed:
            snapshot.appendItems([.failed], toSection: .accountInfo)
        }
        snapshot.appendItems([.row(.dataExport), .row(.deactivate)], toSection: .management)
        if lifecycle != nil {
            snapshot.appendItems([.row(.delete)], toSection: .management)
        }
        return snapshot
    }

    /// The failed row's retry: the skeleton comes back while it runs (so a
    /// second tap finds no row to hit), and a read that fails again keeps
    /// the failed row and says so with a toast.
    private func retryAccount() {
        Task { [weak self] in
            guard let self else { return }
            guard await viewModel.load() == false else { return }
            Feedback.failure("Couldn't load your account details", from: self)
        }
    }

    /// After the date of birth, the email or the phone changed: re-read the
    /// account. A failed re-read shows the failed row rather than the
    /// pre-edit values — see `AccountDetailsViewModel.reloadAfterEdit`.
    private func reloadAfterEdit() {
        Task { await viewModel.reloadAfterEdit() }
    }

    private func render() {
        let snapshot = makeSnapshot(for: viewModel.phase)
        let current = dataSource.snapshot()
        let shown = current.sectionIdentifiers.contains(.accountInfo) ? current.itemIdentifiers(inSection: .accountInfo) : []
        guard shown == snapshot.itemIdentifiers(inSection: .accountInfo) else {
            // Skeleton, values or failed row: cross-dissolve so the shimmer
            // melts into what replaced it rather than snapping.
            UIView.transition(with: collectionView, duration: 0.3, options: .transitionCrossDissolve) {
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
            return
        }
        // Same rows, new values (a refresh after an edit).
        var refreshed = snapshot
        refreshed.reconfigureItems(Self.accountInfoRows.filter { refreshed.indexOfItem($0) != nil })
        dataSource.apply(refreshed, animatingDifferences: false)
    }

    // MARK: - Row rendering

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        switch row {
        case .email:
            valueCell(cell, label: "Email", value: details?.email, verified: details?.emailVerified)
        case .phone:
            valueCell(cell, label: "Phone", value: details?.phone.isEmpty == false ? details?.phone : "Not set", verified: details?.phoneVerified)
        case .birthDate:
            valueCell(cell, label: "Date of Birth", value: Self.birthDateText(details?.dateOfBirth), verified: nil)
            // Set once; afterwards a tap only explains how to correct it.
            if details?.dateOfBirth != nil { cell.accessories = [] }
        case .deactivate:
            actionCell(cell, label: "Deactivate Account", destructive: true)
        case .delete:
            actionCell(cell, label: "Delete Account", destructive: true)
            cell.accessories = [.disclosureIndicator()]
        case .dataExport:
            actionCell(cell, label: "Download Your Data", destructive: false)
            if lifecycle != nil { cell.accessories = [.disclosureIndicator()] }
        }
    }

    /// `[Label]  [value] (✓) ›` — a value row that pushes an editor.
    /// "12 March 2001", or "Add" while none is on file.
    static func birthDateText(_ birthDate: BirthDate?) -> String {
        guard let date = birthDate?.date() else { return "Add" }
        return DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none)
    }

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
        case .birthDate:
            if details?.dateOfBirth != nil {
                presentInfo("Only you can see your date of birth. To correct it, contact support.")
            } else if let setter = account as? any AccountBirthDateSetting {
                push(BirthDateViewController(setter: setter, onSaved: { [weak self] in self?.reloadAfterEdit() }))
            } else {
                presentInfo("Adding your date of birth isn't available yet.")
            }
        case .phone:
            pushPhoneEditor()
        case .deactivate:
            guard deactivator != nil, stepUp != nil else {
                presentInfo("Deactivating isn't available yet. You can delete your account instead.")
                return
            }
            confirmDeactivation()
        case .delete:
            guard let lifecycle else { return }
            push(DeleteAccountViewController(
                viewModel: DeleteAccountViewModel(lifecycle: lifecycle, checklist: deletionChecklist),
                onAccountDeleted: onAccountDeleted,
                makeDataExport: { [weak self] in self?.makeDataExport() },
                stepUp: stepUp,
                canceller: lifecycle as? any AccountDeletionCancelling
            ))
        case .dataExport:
            guard let export = makeDataExport() else {
                confirmComingSoonAction(title: "Request Data Export?", confirm: "Request Export", message: "Data export isn't available yet.")
                return
            }
            push(export)
        }
    }

    /// The new address, a code to it, then the change (#393). The list shows
    /// the stored address once the server has it, and says so.
    private func pushContactChange(_ kind: ContactKind) {
        guard let contactChanger else { return }
        let current = kind == .email ? details?.email : (details?.phone.isEmpty == false ? details?.phone : nil)
        push(ChangeContactViewController(
            kind: kind, current: current, changer: contactChanger, stepUp: stepUp
        ) { [weak self] stored in
            guard let self else { return }
            reportReadOnly(Self.contactChangedNotice(kind, to: stored))
            reloadAfterEdit()
            navigationController?.popToViewController(self, animated: true)
        })
    }

    static func contactChangedNotice(_ kind: ContactKind, to address: String) -> String {
        kind == .email
            ? "Your email is now \(address). Use it the next time you sign in."
            : "Your phone number is now \(address)."
    }

    private func pushEmailEditor() {
        if contactChanger != nil { return pushContactChange(.email) }
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
        if contactChanger != nil { return pushContactChange(.phone) }
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

    private func makeDataExport() -> UIViewController? {
        lifecycle.map { DataExportViewController(viewModel: DataExportViewModel(lifecycle: $0), email: details?.email) }
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

    // MARK: - Deactivation (#385)

    static let deactivationExplanation = "Your profiles are hidden from everyone until you log back in. Logging in again reactivates your account; nothing is deleted."

    private func confirmDeactivation() {
        let sheet = UIAlertController(
            title: "Deactivate your account?", message: Self.deactivationExplanation, preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Continue", style: .destructive) { [weak self] _ in
            self?.askPasswordAndDeactivate()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    /// The server gates deactivation behind a fresh step-up, so the password
    /// comes first; the deactivation runs on the token it mints.
    private func askPasswordAndDeactivate() {
        guard let stepUp, let deactivator else { return }
        StepUpPrompt.present(
            on: self,
            message: "To deactivate your account, confirm it's you.",
            actionTitle: "Deactivate",
            stepUp: stepUp,
            onVerified: { [weak self] in
                Task { @MainActor [weak self] in
                    do {
                        try await deactivator.deactivate()
                        self?.presentDeactivated()
                    } catch AccountError.stepUpRequired {
                        // The proof expired between the two calls: ask again.
                        self?.askPasswordAndDeactivate()
                    } catch {
                        self?.presentInfo("Couldn't deactivate your account. Try again.")
                    }
                }
            },
            onFailure: { [weak self] _ in
                self?.presentInfo("Couldn't confirm your password. Check your connection and try again.")
            }
        )
    }

    private func presentDeactivated() {
        let alert = UIAlertController(
            title: "Account Deactivated",
            message: "Log in any time to reactivate it. Your profiles are hidden until then.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.onDeactivated()
        })
        present(alert, animated: true)
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
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let row): handle(row)
        case .failed: retryAccount()
        case .skeleton, nil: break
        }
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
