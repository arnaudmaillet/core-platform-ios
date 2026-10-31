import AuthInterface
import AuthenticationServices
import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Security and Login → Passkeys (#551, backend #808): the
/// account's passkeys, one more from this device, one less.
///
/// Adding and removing need a recent proof of the holder. The screen tries
/// first and asks only when the server says so (`stepUpRequired`): a proof
/// from a minute ago — the two-step screen's, a sign-in's — still counts.
/// Not optimistic: the list changes once the server has.
final class PasskeysViewController: UIViewController {
    static let title = "Passkeys"

    private enum Section: Hashable {
        case passkeys, add
    }

    private enum Item: Hashable {
        case loading, failed, unavailable, empty
        case passkey(PasskeySummary)
        case add
        /// Discreet (#964): staff only, with a grant handed out of band.
        case addStaff
    }

    let model: PasskeysModel
    private let stepUp: any CredentialStepUp
    /// The passkey step-up (#964), tried first once the account has one.
    private let passkeyStepUp: (any PasskeyStepUp)?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(model: PasskeysModel, stepUp: any CredentialStepUp, passkeyStepUp: (any PasskeyStepUp)? = nil) {
        self.model = model
        self.stepUp = stepUp
        self.passkeyStepUp = passkeyStepUp
        super.init(nibName: nil, bundle: nil)
        title = Self.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .passkey(let passkey)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                self?.remove(passkey)
                done(false)
            }
            return UISwipeActionsConfiguration(actions: [remove])
        }
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        model.onChange = { [weak self] in self?.applySnapshot() }
        applySnapshot()
        Task { await model.load() }
    }

    // MARK: - Copy

    static let footer = "A passkey lets you confirm it\u{2019}s you with Face ID or Touch ID instead of a code. It\u{2019}s saved in your iCloud Keychain, so it works on your other Apple devices too."
    static let unavailableText = "Passkeys aren\u{2019}t available yet."

    /// "Staff · Added 3 Oct 2026 · Last used yesterday" — or "Never used".
    static func subtitle(for passkey: PasskeySummary, now: Date = Date()) -> String {
        var parts: [String] = passkey.staff ? ["Staff"] : []
        if let created = passkey.createdAt {
            parts.append("Added " + created.formatted(date: .abbreviated, time: .omitted))
        }
        if let used = passkey.lastUsedAt {
            let relative = RelativeDateTimeFormatter()
            relative.dateTimeStyle = .named
            parts.append("Last used " + relative.localizedString(for: used, relativeTo: now))
        } else {
            parts.append("Never used")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.cell()
            cell.accessories = []
            switch item {
            case .loading:
                content.text = "Loading\u{2026}"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content.text = FailureCopy.row(
                    for: self?.model.loadFailure, fallback: "Couldn\u{2019}t load your passkeys. Tap to try again."
                )
                content.textProperties.color = .secondaryLabel
            case .unavailable:
                content.text = Self.unavailableText
                content.textProperties.color = .secondaryLabel
            case .empty:
                content.text = "No passkeys yet"
                content.textProperties.color = .secondaryLabel
            case .passkey(let passkey):
                content = .subtitleCell()
                content.text = passkey.name
                content.secondaryText = Self.subtitle(for: passkey)
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: passkey.staff ? "person.badge.shield.checkmark" : "person.badge.key")
                content.imageProperties.tintColor = .label
            case .add:
                content.text = "Add a Passkey"
                content.textProperties.color = .tintColor
            case .addStaff:
                content.text = "Register a Staff Passkey\u{2026}"
                content.textProperties.color = .secondaryLabel
                content.textProperties.font = .appFont(forTextStyle: .footnote)
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .passkeys ? Self.footer : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.passkeys])
        switch model.phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .passkeys)
        case .failed:
            snapshot.appendItems([.failed], toSection: .passkeys)
        case .unavailable:
            snapshot.appendItems([.unavailable], toSection: .passkeys)
        case .loaded(let passkeys):
            snapshot.appendItems(passkeys.isEmpty ? [.empty] : passkeys.map(Item.passkey), toSection: .passkeys)
            snapshot.appendSections([.add])
            snapshot.appendItems([.add, .addStaff], toSection: .add)
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    func add() {
        run(
            { await $0.add() },
            stepUpMessage: "To add a passkey, confirm it\u{2019}s you.", actionTitle: "Continue"
        )
    }

    /// A staff passkey (#964): the grant an admin handed out, pasted, then
    /// the usual registration with it. ⚠️ The grant is a secret: it lives in
    /// this alert and the call, nowhere else.
    private func addStaff() {
        let alert = UIAlertController(
            title: "Register a Staff Passkey",
            message: "Paste the enrollment code you were given. It works once, for 24 hours.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Enrollment code"
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.textContentType = .oneTimeCode
        }
        let register = UIAlertAction(title: "Continue", style: .default) { [weak self, weak alert] _ in
            let grant = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self, !grant.isEmpty else { return }
            run(
                { await $0.add(staffGrant: grant) },
                stepUpMessage: "To add a passkey, confirm it\u{2019}s you.", actionTitle: "Continue"
            )
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(register)
        present(alert, animated: true)
    }

    private func remove(_ passkey: PasskeySummary) {
        let confirm = UIAlertController(
            title: "Remove \u{201C}\(passkey.name)\u{201D}?",
            message: "You won\u{2019}t be able to use it to confirm it\u{2019}s you any more.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.run(
                { await $0.remove(passkey) },
                stepUpMessage: "To remove a passkey, confirm it\u{2019}s you.", actionTitle: "Remove"
            )
        })
        present(confirm, animated: true)
    }

    /// Runs an action; a step-up asked for is done once, then the action
    /// again.
    private func run(
        _ action: @escaping (PasskeysModel) async -> PasskeysModel.Outcome,
        stepUpMessage: String,
        actionTitle: String,
        afterStepUp: Bool = false
    ) {
        Task { [weak self] in
            guard let self else { return }
            switch await action(model) {
            case .done, .cancelled:
                break
            case .needsStepUp where !afterStepUp:
                StepUpPrompt.presentPreferringPasskey(
                    model.hasPasskeys ? passkeyStepUp.map { ($0, model.authorizer) } : nil,
                    on: self,
                    message: stepUpMessage,
                    actionTitle: actionTitle,
                    stepUp: stepUp,
                    onVerified: { [weak self] in
                        self?.run(action, stepUpMessage: stepUpMessage, actionTitle: actionTitle, afterStepUp: true)
                    },
                    onFailure: { [weak self] error in self?.presentFailure(PasskeysModel.failureMessage(error)) }
                )
            case .needsStepUp:
                presentFailure(PasskeysModel.failureMessage(PasskeyError.stepUpRequired))
            case .failed(let message):
                presentFailure(message)
            }
        }
    }

    private func presentFailure(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension PasskeysViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed, .add, .addStaff, .passkey: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed: Task { await model.load() }
        case .add: add()
        case .addStaff: addStaff()
        case .passkey(let passkey): remove(passkey)
        default: break
        }
    }
}

// MARK: - Model

/// The screen's round trips and what they leave it showing — its own type
/// so they can be driven without a window.
@MainActor
final class PasskeysModel {
    enum Phase: Equatable {
        case loading
        case loaded([PasskeySummary])
        /// The server has no passkeys configured (UNAVAILABLE).
        case unavailable
        case failed
    }

    enum Outcome: Equatable {
        case done
        /// The person backed out of the system sheet.
        case cancelled
        /// The server wants a fresh proof of the holder first.
        case needsStepUp
        /// What to tell the person.
        case failed(String)
    }

    /// What a new passkey is called: Apple's passkeys live in iCloud
    /// Keychain, which is what the holder will recognise.
    static let newPasskeyName = "iCloud Keychain"
    /// A staff passkey's name, beside its badge.
    static let staffPasskeyName = "Staff passkey"

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// Why the last load failed (#794), set before the phase.
    private(set) var loadFailure: NetworkFailure?
    var onChange: (() -> Void)?
    private var isWorking = false

    private let manager: any PasskeysManaging
    let authorizer: any PasskeyAuthorizing

    /// The account holds at least one passkey — one to step up with.
    var hasPasskeys: Bool {
        if case .loaded(let passkeys) = phase { !passkeys.isEmpty } else { false }
    }

    init(manager: any PasskeysManaging, authorizer: any PasskeyAuthorizing) {
        self.manager = manager
        self.authorizer = authorizer
    }

    func load() async {
        if phase == .failed { phase = .loading }
        do {
            phase = .loaded(try await manager.listPasskeys())
        } catch PasskeyError.unavailable {
            phase = .unavailable
        } catch {
            loadFailure = NetworkFailure.of(error)
            phase = .failed
        }
    }

    func add(staffGrant: String? = nil) async -> Outcome {
        guard !isWorking else { return .cancelled }
        isWorking = true
        defer { isWorking = false }
        do {
            let request = try await manager.startPasskeyRegistration()
            let attestation = try await authorizer.createPasskey(request)
            let passkey = try await manager.finishPasskeyRegistration(
                request, attestation: attestation, name: staffGrant == nil ? Self.newPasskeyName : Self.staffPasskeyName,
                staffGrant: staffGrant
            )
            if case .loaded(let passkeys) = phase {
                phase = .loaded(passkeys + [passkey])
            } else {
                await load()
            }
            return .done
        } catch {
            return await outcome(for: error)
        }
    }

    func remove(_ passkey: PasskeySummary) async -> Outcome {
        guard !isWorking else { return .cancelled }
        isWorking = true
        defer { isWorking = false }
        do {
            phase = .loaded(try await manager.removePasskey(id: passkey.id))
            return .done
        } catch {
            return await outcome(for: error)
        }
    }

    private func outcome(for error: Error) async -> Outcome {
        switch error {
        case is PasskeyCancelled:
            return .cancelled
        case let error as ASAuthorizationError where error.code == .matchedExcludedCredential:
            // This device's keychain already holds one for the account.
            return .failed(Self.failureMessage(PasskeyError.alreadyRegistered))
        case PasskeyError.stepUpRequired:
            return .needsStepUp
        case PasskeyError.unavailable:
            phase = .unavailable
            return .done
        case PasskeyError.notFound, PasskeyError.alreadyRegistered:
            // The list is stale: catch up underneath the alert.
            await load()
            return .failed(Self.failureMessage(error))
        default:
            return .failed(Self.failureMessage(error))
        }
    }

    static func failureMessage(_ error: Error) -> String {
        switch error as? PasskeyError {
        case .stepUpRequired: "For your security, confirm it\u{2019}s you again, then try once more."
        case .restart: "That took too long. Try adding the passkey again."
        case .notAccepted: "This passkey couldn\u{2019}t be added. Try again."
        case .limitReached: "You can have up to 10 passkeys. Remove one to add another."
        case .alreadyRegistered: "This device already has a passkey for your account."
        case .notFound: "That passkey was already removed."
        case .grantRejected: "That enrollment code didn\u{2019}t work. It may have expired or already been used \u{2014} ask for a new one."
        case .unavailable: unavailableText
        default: FailureCopy.message(for: error, fallback: "Couldn\u{2019}t change your passkeys. Try again.")
        }
    }

    private static var unavailableText: String { PasskeysViewController.unavailableText }
}

// MARK: - How it is left (#1144)

extension PasskeysViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
