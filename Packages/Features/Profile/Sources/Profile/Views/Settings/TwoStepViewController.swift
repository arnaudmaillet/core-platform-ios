import CoreImage.CIFilterBuiltins
import CoreNetworking
import DesignSystem
import UIKit

/// Settings → Security and Login → Two-Step Sign-In (#383, backend #649).
///
/// Off: one way in, behind the password — the app's QR code, then its first
/// code, then the backup codes. On: new backup codes, or off, each behind a
/// code from the app (the proof every account has once two-step is on,
/// password or not). Not optimistic: the screen changes once the server has.
final class TwoStepViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        /// `codesLeft`: unused backup codes (#405); 0 when off.
        case loaded(isOn: Bool, codesLeft: Int)
        case failed
    }

    /// Few enough that the screen says to get new ones.
    static let lowOnCodes = 2

    enum Section: Hashable {
        case status, backupCodes, toggle
    }

    private enum Item: Hashable {
        case loading, failed
        case status(isOn: Bool)
        case codesLeft(Int)
        case turnOn, newBackupCodes, turnOff
    }

    private let account: any AccountProviding
    private let manager: any TwoStepManaging
    private let stepUp: any CredentialStepUp
    private(set) var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private var loadFailure: NetworkFailure?
    private var isWorking = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(account: any AccountProviding, manager: any TwoStepManaging, stepUp: any CredentialStepUp) {
        self.account = account
        self.manager = manager
        self.stepUp = stepUp
        super.init(nibName: nil, bundle: nil)
        title = "Two-Step Sign-In"
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

    func load() {
        if case .failed = phase { phase = .loading }
        Task { [weak self] in
            guard let self else { return }
            do {
                let details = try await account.currentAccount()
                phase = .loaded(isOn: details.twoStepOn, codesLeft: details.backupCodesLeft)
            } catch {
                loadFailure = NetworkFailure.of(error)
                phase = .failed
            }
        }
    }

    static func footer(_ section: Section, isOn: Bool, codesLeft: Int = 10) -> String? {
        switch section {
        case .status:
            isOn
                ? "When you sign in, you enter a code from your authenticator app after your password, emailed code or Apple ID."
                : "Add a code from an authenticator app — like Passwords, Google Authenticator or 1Password — to every sign-in, so your password alone isn't enough."
        case .backupCodes:
            (codesLeft <= lowOnCodes
                ? (codesLeft == 0 ? "You have no backup codes left. " : "You're running low on backup codes. ")
                : "")
                + "Each backup code works once, when you can't use your authenticator app. Getting new ones stops the old ones and logs out your other devices."
        case .toggle:
            isOn ? "Signing in will need only your password, emailed code or Apple ID." : nil
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.valueCell()
            cell.accessories = []
            switch item {
            case .loading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                // "You’re offline…" when that is why (#794).
                content.text = FailureCopy.row(
                    for: self?.loadFailure, fallback: "Couldn't load two-step sign-in. Tap to try again."
                )
                content.textProperties.color = .secondaryLabel
            case .status(let isOn):
                content.text = "Two-Step Sign-In"
                content.secondaryText = isOn ? "On" : "Off"
                content.image = UIImage(systemName: isOn ? "checkmark.shield.fill" : "shield")
                content.imageProperties.tintColor = isOn ? .systemGreen : .secondaryLabel
            case .turnOn:
                content = .cell()
                content.text = "Turn On Two-Step Sign-In"
                content.textProperties.color = .tintColor
            case .codesLeft(let count):
                content.text = "Codes Left"
                content.secondaryText = String(count)
                content.secondaryTextProperties.color = count <= Self.lowOnCodes ? .systemOrange : .secondaryLabel
            case .newBackupCodes:
                content = .cell()
                content.text = "Get New Backup Codes"
                content.textProperties.color = .tintColor
            case .turnOff:
                content = .cell()
                content.text = "Turn Off Two-Step Sign-In"
                content.textProperties.color = .systemRed
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .backupCodes ? "Backup Codes" : nil
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            if case .loaded(let isOn, let codesLeft) = phase, let section = dataSource.sectionIdentifier(for: indexPath.section) {
                content.text = Self.footer(section, isOn: isOn, codesLeft: codesLeft)
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
        snapshot.appendSections([.status])
        switch phase {
        case .loading:
            snapshot.appendItems([.loading], toSection: .status)
        case .failed:
            snapshot.appendItems([.failed], toSection: .status)
        case .loaded(let isOn, let codesLeft):
            snapshot.appendItems([.status(isOn: isOn)], toSection: .status)
            if isOn {
                snapshot.appendSections([.backupCodes, .toggle])
                snapshot.appendItems([.codesLeft(codesLeft), .newBackupCodes], toSection: .backupCodes)
                snapshot.appendItems([.turnOff], toSection: .toggle)
            } else {
                snapshot.appendSections([.toggle])
                snapshot.appendItems([.turnOn], toSection: .toggle)
            }
        }
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    private func turnOn() {
        StepUpPrompt.present(
            on: self,
            message: "To turn on two-step sign-in, enter your password.",
            actionTitle: "Continue",
            stepUp: stepUp,
            onVerified: { [weak self] in self?.startEnrollment() },
            onFailure: { [weak self] error in self?.presentFailure(error) }
        )
    }

    /// The setup screen on the stack, while it is there: a second tap lands
    /// on it instead of pushing another one.
    private weak var enrollmentScreen: TwoStepEnrollmentViewController?

    /// ⚠️ PUSHES AT ONCE, THEN THE SCREEN FETCHES ITS SECRET (#800). This
    /// used to await `startTwoStepEnrollment()` before pushing: for the whole
    /// round trip the password alert had gone and nothing happened, which
    /// reads as a tap that didn't take — so people tapped again. The setup
    /// screen now arrives on its own skeleton, starts the enrolment itself,
    /// and keeps a failure inside it (with Try Again) instead of an alert
    /// over a screen that never moved.
    ///
    /// Synchronous on purpose: by the time this returns the screen is on the
    /// stack, whatever the network is doing.
    func startEnrollment() {
        guard enrollmentScreen == nil, let navigationController else { return }
        let setup = TwoStepEnrollmentViewController(
            model: enrollmentModelForPush(),
            manager: manager,
            stepUp: stepUp,
            onEnabled: { [weak self] codes in self?.didTurnOn(with: codes) }
        )
        enrollmentScreen = setup
        navigationController.pushViewController(setup, animated: true)
    }

    /// The last setup's round trip, kept past its screen.
    private var enrollmentModel: TwoStepEnrollmentModel?

    /// ⚠️ ONE START IN FLIGHT PER SCREEN, EVEN ACROSS A POP (#800). Back out
    /// of the setup screen while its start is out and set up again: a fresh
    /// model would mint a second secret, and if the first answer reached the
    /// server last, the QR code would show a seed the server had already
    /// replaced — the app's first code would never match. So a pending start
    /// is reused by the next push; once it has answered (secret or failure),
    /// the next setup starts clean, since nothing else can race it.
    func enrollmentModelForPush() -> TwoStepEnrollmentModel {
        if let pending = enrollmentModel, pending.isStarting { return pending }
        let model = TwoStepEnrollmentModel(manager: manager)
        model.onFailure = { [weak self] error in
            // On (or off) somewhere else: this screen catches up underneath.
            if case .alreadyChanged? = error as? TwoStepError { self?.load() }
        }
        enrollmentModel = model
        return model
    }

    /// Turned on: the backup codes replace the setup screen, and this one
    /// says On underneath.
    private func didTurnOn(with codes: BackupCodes) {
        phase = .loaded(isOn: true, codesLeft: codes.codes.count)
        showBackupCodes(codes)
    }

    private func newBackupCodes() {
        StepUpPrompt.present(
            on: self,
            message: "Enter a code from your authenticator app, or a backup code. Your old backup codes will stop working.",
            actionTitle: "Get New Codes",
            stepUp: stepUp,
            credential: .code,
            onVerified: { [weak self] in self?.regenerate() },
            onFailure: { [weak self] error in self?.presentFailure(error) }
        )
    }

    private func regenerate() {
        guard !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                let codes = try await manager.regenerateBackupCodes()
                phase = .loaded(isOn: true, codesLeft: codes.codes.count)
                showBackupCodes(codes)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func turnOff() {
        StepUpPrompt.present(
            on: self,
            title: "Turn Off Two-Step Sign-In?",
            message: "Enter a code from your authenticator app, or a backup code.",
            actionTitle: "Turn Off",
            stepUp: stepUp,
            credential: .code,
            onVerified: { [weak self] in self?.disable() },
            onFailure: { [weak self] error in self?.presentFailure(error) }
        )
    }

    private func disable() {
        guard !isWorking else { return }
        isWorking = true
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                try await manager.disableTwoStep()
                phase = .loaded(isOn: false, codesLeft: 0)
            } catch {
                presentFailure(error)
            }
        }
    }

    /// The codes over whatever is on top of this screen (the setup screen),
    /// so Done comes back here.
    private func showBackupCodes(_ codes: BackupCodes) {
        guard let navigationController else { return }
        let list = BackupCodesViewController(codes: codes) { [weak self] in
            guard let self else { return }
            self.navigationController?.popToViewController(self, animated: true)
        }
        var stack = navigationController.viewControllers
        if let index = stack.firstIndex(where: { $0 === self }) { stack = Array(stack[...index]) }
        navigationController.setViewControllers(stack + [list], animated: true)
    }

    static func failureMessage(_ error: Error) -> String {
        switch error as? TwoStepError {
        case .stepUpRequired: "For your security, confirm it's you again, then try once more."
        case .alreadyChanged: "Two-step sign-in was changed somewhere else. The screen is up to date now."
        case .enrollmentExpired: "Setup timed out. Start again."
        case .wrongCode: "That code didn't match. Check your authenticator app and try again."
        default: "Couldn't change two-step sign-in. Try again."
        }
    }

    private func presentFailure(_ error: Error) {
        if case .alreadyChanged? = error as? TwoStepError { load() }
        let alert = UIAlertController(title: nil, message: Self.failureMessage(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension TwoStepViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed, .turnOn, .newBackupCodes, .turnOff: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .failed: load()
        case .turnOn: turnOn()
        case .newBackupCodes: newBackupCodes()
        case .turnOff: turnOff()
        default: break
        }
    }
}

// MARK: - Setup

/// The setup screen's one round trip: `StartMfaEnrollment`, from loading to
/// the secret, or to a failure that Try Again starts over (#800).
///
/// Its own type so the states can be driven and read without a window: the
/// screen only draws whatever this says.
@MainActor
final class TwoStepEnrollmentModel {
    enum State: Equatable {
        case loading
        case ready(TwoStepEnrollment)
        /// `message`: what went wrong, in the screen's words; `recovery`:
        /// the way out the failed state offers.
        case failed(message: String, recovery: Recovery)
    }

    /// ⚠️ NOT EVERY FAILURE IS RETRIED THE SAME WAY. Starting again only
    /// fixes what the next round trip can fix: a stale step-up fails every
    /// start until the password is asked again, and two-step changed
    /// elsewhere fails every start for good — Try Again there would be a
    /// button that never works.
    enum Recovery: Equatable {
        /// Start again (the network, the server having a moment).
        case retry
        /// Ask for the password again, then start (`stepUpRequired`).
        case stepUp
        /// Nothing to set up any more: back to the Two-Step screen, which
        /// has reloaded underneath (`alreadyChanged`).
        case back
    }

    static func recovery(for error: Error) -> Recovery {
        switch error as? TwoStepError {
        case .stepUpRequired: .stepUp
        case .alreadyChanged: .back
        default: .retry
        }
    }

    private(set) var state: State = .loading {
        didSet { if state != oldValue { onChange?(state) } }
    }

    /// Every change of `state`, on the main actor.
    var onChange: ((State) -> Void)?
    /// The error behind a `.failed`, for whoever has to react to it beyond
    /// this screen (an `alreadyChanged` makes the screen under it reload).
    var onFailure: ((Error) -> Void)?

    private let manager: any TwoStepManaging
    private var inFlight: Task<Void, Never>?

    init(manager: any TwoStepManaging) {
        self.manager = manager
    }

    /// A start is out and hasn't answered.
    var isStarting: Bool { inFlight != nil }

    /// Starts the enrolment — first time, or again after a failure.
    ///
    /// One round trip at a time, and none once the secret is here: each
    /// start mints a NEW secret server-side, so a second one racing the first
    /// would leave the QR code on screen pointing at a seed the server has
    /// already replaced, and the app's first code would never match.
    func start() {
        guard inFlight == nil else { return }
        if case .ready = state { return }
        state = .loading
        inFlight = Task { [weak self, manager] in
            let result: Result<TwoStepEnrollment, Error>
            do {
                result = .success(try await manager.startTwoStepEnrollment())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            inFlight = nil
            switch result {
            case .success(let enrollment):
                state = .ready(enrollment)
            case .failure(let error):
                state = .failed(message: TwoStepViewController.failureMessage(error), recovery: Self.recovery(for: error))
                onFailure?(error)
            }
        }
    }
}

/// Turning two-step on: the account goes into the authenticator app (QR code,
/// Add to Passwords, or the setup key typed by hand), and the app's first
/// code turns it on.
///
/// ⚠️ PUSHED BEFORE ITS SECRET EXISTS (#800). The screen fetches the
/// enrolment itself: until it answers, the QR code, the button and the setup
/// key are skeleton bones in their own shapes (the steps' words are already
/// there — they don't depend on the answer); a failure replaces the whole
/// screen with what went wrong and its way out (`Recovery`), never a blank
/// screen or a spinner that never ends.
///
/// The model comes from the Two-Step screen, which keeps a pending start
/// across a pop so a re-push never mints a second secret.
final class TwoStepEnrollmentViewController: UIViewController {
    let model: TwoStepEnrollmentModel
    private let manager: any TwoStepManaging
    private let stepUp: any CredentialStepUp
    /// Asks for the password, then runs its closure once the step-up has
    /// gone through. Nil: the password alert. A test hands in its own (an
    /// alert never finishes presenting in the test host).
    var presentStepUp: ((@escaping () -> Void) -> Void)?
    private let onEnabled: (BackupCodes) -> Void
    private let codeField = UITextField()
    let scroll = UIScrollView()
    /// The failed state: what went wrong, and Try Again.
    let failureView = EmptyStateView()
    /// Where the QR code, Add to Passwords and the setup key go — bones
    /// until the enrolment answers.
    private let secretSlot = UIStackView()
    private var enrollment: TwoStepEnrollment?
    private var isConfirming = false

    init(
        model: TwoStepEnrollmentModel,
        manager: any TwoStepManaging,
        stepUp: any CredentialStepUp,
        onEnabled: @escaping (BackupCodes) -> Void
    ) {
        self.model = model
        self.manager = manager
        self.stepUp = stepUp
        self.onEnabled = onEnabled
        super.init(nibName: nil, bundle: nil)
        title = "Set Up"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Turn On", style: .prominent, target: self, action: #selector(confirm)
        )
        navigationItem.rightBarButtonItem?.isEnabled = false

        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.prefersSoftTopEdge()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Spacing.md
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        stack.addArrangedSubview(Self.label("1. Add your account to an authenticator app", style: .headline))
        stack.addArrangedSubview(Self.label(
            "Scan the code with another device's camera, or tap Add to Passwords on this iPhone.",
            style: .subheadline, color: .secondaryLabel
        ))
        secretSlot.axis = .vertical
        secretSlot.spacing = Spacing.md
        secretSlot.alignment = .fill
        stack.addArrangedSubview(secretSlot)

        stack.setCustomSpacing(Spacing.xl, after: secretSlot)
        stack.addArrangedSubview(Self.label("2. Enter the 6-digit code it shows", style: .headline))
        codeField.placeholder = "6-digit code"
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.textAlignment = .center
        codeField.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        codeField.borderStyle = .roundedRect
        codeField.accessibilityLabel = "Code from your authenticator app"
        codeField.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)
        // The field sits at the bottom: keep it above the keyboard.
        codeField.addAction(UIAction { [weak self] _ in self?.revealCodeField() }, for: .editingDidBegin)
        codeField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        stack.addArrangedSubview(codeField)

        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        view.addSubview(failureView)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        model.onChange = { [weak self] state in self?.render(state) }
        render(model.state)
        model.start()
    }

    /// The failed state's action: start again, ask for the password first,
    /// or go back — whichever can actually get past this failure.
    func recover() {
        guard case .failed(_, let recovery) = model.state else { return }
        switch recovery {
        case .retry:
            model.start()
        case .stepUp:
            let start: () -> Void = { [weak self] in self?.model.start() }
            if let presentStepUp {
                presentStepUp(start)
            } else {
                StepUpPrompt.present(
                    on: self,
                    message: "To turn on two-step sign-in, enter your password.",
                    actionTitle: "Continue",
                    stepUp: stepUp,
                    onVerified: start,
                    onFailure: { [weak self] error in self?.presentMessage(TwoStepViewController.failureMessage(error)) }
                )
            }
        case .back:
            navigationController?.popViewController(animated: true)
        }
    }

    // MARK: States

    private func render(_ state: TwoStepEnrollmentModel.State) {
        secretSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .loading:
            enrollment = nil
            scroll.isHidden = false
            failureView.isHidden = true
            let bones = UIStackView(arrangedSubviews: loadingSecret())
            bones.axis = .vertical
            bones.spacing = secretSlot.spacing
            bones.isUserInteractionEnabled = false
            bones.isAccessibilityElement = true
            bones.accessibilityLabel = "Loading setup code"
            secretSlot.addArrangedSubview(bones)
        case .ready(let enrollment):
            self.enrollment = enrollment
            scroll.isHidden = false
            failureView.isHidden = true
            secret(for: enrollment).forEach(secretSlot.addArrangedSubview)
        case .failed(let message, let recovery):
            enrollment = nil
            scroll.isHidden = true
            failureView.configure(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't Start Setup",
                subtitle: message,
                actionTitle: Self.actionTitle(for: recovery),
                actionHandler: { [weak self] in self?.recover() }
            )
            failureView.isHidden = false
            codeField.resignFirstResponder()
        }
        // Nothing to type a code for until there is a secret to put in the app.
        codeField.isEnabled = enrollment != nil
        codeChanged()
    }

    static func actionTitle(for recovery: TwoStepEnrollmentModel.Recovery) -> String {
        recovery == .back ? "Back" : "Try Again"
    }

    /// What a setup key looks like before there is one: as long as the
    /// mock's (and the server's) 16-character base32 seed, so the key's bone
    /// wraps as the key will.
    private static let placeholderSecret = String(repeating: "X", count: 16)

    /// ⚠️ THE BONES ARE THE REAL VIEWS, INVISIBLE (#800). Fixed-size bones
    /// guessed the button heights and the caption's line, so the screen
    /// jumped when the secret landed — and further at larger text sizes.
    /// Here each bone is laid over the very view that will replace it (built
    /// by the same factory, drawn at alpha 0), so it has that view's height
    /// at every Dynamic Type size, and the caption's bone is one line of its
    /// own font tall. The QR plate keeps its fixed size.
    private func loadingSecret() -> [UIView] {
        let plate = SkeletonBoneView(rounding: .fixed(16))
        let caption = Self.setupKeyCaption()
        return [
            Self.qrHolder(around: plate),
            Self.underBone(addToPasswordsButton()),
            Self.underBone(caption, rounding: .capsule, widthFraction: 0.5),
            Self.underBone(setupKeyButton(grouped: Self.placeholderSecret, secret: "")),
        ]
    }

    private func secret(for enrollment: TwoStepEnrollment) -> [UIView] {
        // A white plate with a margin around the code: scanners need the
        // quiet zone, and a dark-mode background would otherwise touch it.
        let plate = UIView()
        plate.backgroundColor = .white
        plate.layer.cornerRadius = 16
        plate.isAccessibilityElement = true
        plate.accessibilityLabel = "QR code for your authenticator app"
        let qr = UIImageView(image: Self.qrCode(for: enrollment.otpauthURI))
        qr.contentMode = .scaleAspectFit
        qr.layer.magnificationFilter = .nearest
        plate.addSubview(qr)
        qr.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qr.topAnchor.constraint(equalTo: plate.topAnchor, constant: 16),
            qr.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -16),
            qr.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 16),
            qr.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -16),
        ])
        return [
            Self.qrHolder(around: plate),
            addToPasswordsButton(),
            Self.setupKeyCaption(),
            setupKeyButton(grouped: enrollment.groupedSecret, secret: enrollment.secret),
        ]
    }

    /// The plate centred on its row: 184 pt of code in a 16 pt quiet zone.
    private static func qrHolder(around plate: UIView) -> UIView {
        let holder = UIView()
        holder.addSubview(plate)
        plate.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            plate.topAnchor.constraint(equalTo: holder.topAnchor),
            plate.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            plate.widthAnchor.constraint(equalToConstant: 216),
            plate.heightAnchor.constraint(equalToConstant: 216),
        ])
        return holder
    }

    private func addToPasswordsButton() -> UIButton {
        var config = UIButton.Configuration.bordered()
        config.title = "Add to Passwords"
        config.image = UIImage(systemName: "key.viewfinder")
        config.imagePadding = 8
        return UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.openAuthenticator() })
    }

    private static func setupKeyCaption() -> UILabel {
        label("Or type this setup key:", style: .subheadline, color: .secondaryLabel)
    }

    private func setupKeyButton(grouped: String, secret: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = grouped
        config.attributedTitle = AttributedString(
            grouped,
            attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)])
        )
        config.image = UIImage(systemName: "doc.on.doc")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.copyKey() })
        button.accessibilityLabel = "Setup key, \(secret). Copy"
        return button
    }

    /// `content`, invisible, with a bone over it: the bone takes the view's
    /// height (and `widthFraction` of its width, from the leading edge).
    private static func underBone(
        _ content: UIView,
        rounding: SkeletonBoneView.Rounding = .fixed(12),
        widthFraction: CGFloat = 1
    ) -> UIView {
        let holder = UIView()
        let bone = SkeletonBoneView(rounding: rounding)
        content.alpha = 0
        content.isAccessibilityElement = false
        content.accessibilityElementsHidden = true
        holder.addSubview(content)
        holder.addSubview(bone)
        content.translatesAutoresizingMaskIntoConstraints = false
        bone.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            bone.topAnchor.constraint(equalTo: content.topAnchor),
            bone.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bone.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bone.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: widthFraction),
        ])
        return holder
    }

    static func cleaned(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(6))
    }

    private func revealCodeField() {
        view.setNeedsLayout()
    }

    /// The keyboard's guide moves the scroll view's bottom in a layout pass:
    /// that is when the field is brought back above it, however long the
    /// keyboard takes to rise.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard codeField.isFirstResponder else { return }
        let frame = codeField.convert(codeField.bounds, to: scroll).insetBy(dx: 0, dy: -Spacing.lg)
        scroll.scrollRectToVisible(frame, animated: false)
    }

    /// The QR code of `text`, sharp at any size.
    static func qrCode(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .appFont(forTextStyle: style)
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func codeChanged() {
        let code = Self.cleaned(codeField.text ?? "")
        codeField.text = code
        navigationItem.rightBarButtonItem?.isEnabled = code.count == 6 && !isConfirming && enrollment != nil
    }

    private func openAuthenticator() {
        guard let uri = enrollment?.otpauthURI, let url = URL(string: uri) else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened else { return }
            self?.presentMessage("No app on this iPhone takes setup codes. Scan the QR code with another device, or type the setup key.")
        }
    }

    /// A copy has no evidence on screen, so it says so (#803): a vibration
    /// alone left the author unsure the key was taken.
    private func copyKey() {
        guard let secret = enrollment?.secret else { return }
        UIPasteboard.general.string = secret
        Feedback.success("Copied", symbol: "doc.on.doc.fill", from: self)
    }

    @objc private func confirm() {
        let code = Self.cleaned(codeField.text ?? "")
        guard code.count == 6, !isConfirming, enrollment != nil else { return }
        isConfirming = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.hidesBackButton = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let codes = try await manager.confirmTwoStepEnrollment(code: code)
                onEnabled(codes)
            } catch TwoStepError.enrollmentExpired {
                presentMessage(TwoStepViewController.failureMessage(TwoStepError.enrollmentExpired)) { [weak self] in
                    self?.navigationController?.popViewController(animated: true)
                }
            } catch {
                codeField.text = ""
                presentMessage(TwoStepViewController.failureMessage(error))
            }
            isConfirming = false
            navigationItem.hidesBackButton = false
            codeChanged()
        }
    }

    private func presentMessage(_ message: String, then: (() -> Void)? = nil) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in then?() })
        present(alert, animated: true)
    }
}

// MARK: - Backup codes

/// The backup codes, shown once: copy or share them, then Done. There is no
/// way back to them afterwards — only new ones.
final class BackupCodesViewController: UIViewController {
    private let codes: BackupCodes
    private let onDone: () -> Void
    private var collectionView: UICollectionView!

    init(codes: BackupCodes, onDone: @escaping () -> Void) {
        self.codes = codes
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        title = "Backup Codes"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func footer(for codes: BackupCodes) -> String {
        var text = "Save these somewhere safe, like your password manager. Each one signs you in once if you can't use your authenticator app. You won't see them again."
        if codes.sessionsSignedOut > 0 {
            text += " Your other devices were logged out."
        }
        return text
    }

    /// All the codes, one per line, for Copy and Share.
    static func plainText(_ codes: BackupCodes) -> String {
        codes.codes.joined(separator: "\n")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.onDone() }
        )
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        view.addSubview(collectionView)

        enum Row: Hashable { case code(String), copy, share }
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.cell()
            switch row {
            case .code(let code):
                content.text = code
                content.textProperties.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
                content.textProperties.alignment = .center
            case .copy:
                content.text = "Copy Codes"
                content.image = UIImage(systemName: "doc.on.doc")
                content.textProperties.color = .tintColor
            case .share:
                content.text = "Share or Save…"
                content.image = UIImage(systemName: "square.and.arrow.up")
                content.textProperties.color = .tintColor
            }
            cell.contentConfiguration = content
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [codes] view, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = indexPath.section == 0 ? Self.footer(for: codes) : nil
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems(codes.codes.map(Row.code), toSection: 0)
        snapshot.appendItems([.copy, .share], toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: false)
        self.dataSource = dataSource
        collectionView.delegate = self
        selectRow = { [weak self] indexPath in
            guard let self else { return }
            switch dataSource.itemIdentifier(for: indexPath) {
            case .copy:
                copyToPasteboard(Self.plainText(codes))
                // Said, not only felt (#803): nothing on screen shows a copy.
                Feedback.success("Copied", symbol: "doc.on.doc.fill", from: self)
            case .share:
                let sheet = UIActivityViewController(activityItems: [Self.plainText(codes)], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = collectionView.cellForItem(at: indexPath)
                present(sheet, animated: true)
            default:
                break
            }
        }
    }

    private var dataSource: AnyObject?
    private var selectRow: ((IndexPath) -> Void)?
    /// Where Copy puts the codes. Swappable for tests: ⚠️ the general
    /// pasteboard in a package test host blocked the main actor until the
    /// run's time limit.
    var copyToPasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }
}

extension BackupCodesViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        selectRow?(indexPath)
    }
}
