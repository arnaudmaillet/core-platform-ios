import CoreNavigation
import CoreNetworking
import DesignSystem
import UIKit

/// Accepts another person's invite code (#417). Never optimistic: the link
/// exists once the server says so, and a refusal keeps the code typed so it
/// can be fixed.
@MainActor
final class SupervisionAcceptModel {
    private let manager: any SupervisionManaging
    /// The viewer's own side, when known: what the copy says, and how a
    /// refusal is worded. Nil until the age is read (a link opened cold).
    var viewerRole: SupervisionRole?
    var code: String
    private(set) var isLinking = false

    init(manager: any SupervisionManaging, code: String = "", viewerRole: SupervisionRole? = nil) {
        self.manager = manager
        self.code = code
        self.viewerRole = viewerRole
    }

    /// The code as the server reads it, or nil while it can't be one yet.
    var normalizedCode: String? { SupervisionInviteCode.normalized(code) }

    var canLink: Bool { normalizedCode != nil && !isLinking }

    /// Links the accounts. Nil while a call is already running or the code
    /// can't be one; otherwise what the server said.
    func link() async -> Result<Supervision, SupervisionError>? {
        guard let code = normalizedCode, !isLinking else { return nil }
        isLinking = true
        defer { isLinking = false }
        do {
            return .success(try await manager.acceptSupervisionInvite(code: code))
        } catch let error as SupervisionError {
            return .failure(error)
        } catch {
            return .failure(.transport(message: "\(error)", failure: NetworkFailure.of(error)))
        }
    }
}

/// Settings → Family and Teens → Enter an Invite Code (#417), also what a
/// `core-platform.click/family/<code>` link opens, with the code filled in.
/// Nothing is linked until the viewer taps Link.
final class SupervisionAcceptViewController: UIViewController {
    let model: SupervisionAcceptModel
    /// Reads the viewer's age when the opener didn't know it (a deep link).
    private let resolveTeen: (() async throws -> Bool)?
    /// The accounts are linked; the opener says so and moves on.
    private let onLinked: (SupervisionAcceptViewController, Supervision) -> Void
    let codeField = UITextField()
    private let explanation = UILabel()
    /// What a teen's link shares (#1116).
    let consentView = SupervisionConsentView()

    init(
        model: SupervisionAcceptModel,
        resolveTeen: (() async throws -> Bool)? = nil,
        onLinked: @escaping (SupervisionAcceptViewController, Supervision) -> Void
    ) {
        self.model = model
        self.resolveTeen = resolveTeen
        self.onLinked = onLinked
        super.init(nibName: nil, bundle: nil)
        title = "Enter Code"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        setOwnTrailingBarItems([linkItem()], animated: false)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.prefersSoftTopEdge()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Spacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        explanation.font = .appFont(forTextStyle: .subheadline)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0
        stack.addArrangedSubview(explanation)
        // What a teen shares by linking, before the code and before Link
        // (#1116): said plainly, not left to the explanation above.
        stack.addArrangedSubview(consentView)

        // A code from a link reads in two halves, as the invite showed it.
        codeField.text = model.normalizedCode.map(SupervisionInviteCode.display) ?? model.code
        codeField.placeholder = "XXXXX-XXXXX"
        codeField.autocapitalizationType = .allCharacters
        codeField.autocorrectionType = .no
        codeField.spellCheckingType = .no
        codeField.smartDashesType = .no
        codeField.returnKeyType = .go
        codeField.textAlignment = .center
        codeField.font = .scaled(.monospacedSystemFont(ofSize: 22, weight: .semibold), relativeTo: .title2)
        codeField.adjustsFontForContentSizeCategory = true
        codeField.borderStyle = .roundedRect
        codeField.accessibilityLabel = "Invite code"
        codeField.addAction(UIAction { [weak self] _ in self?.codeChanged() }, for: .editingChanged)
        codeField.addAction(UIAction { [weak self] _ in self?.link() }, for: .editingDidEndOnExit)
        codeField.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        stack.addArrangedSubview(codeField)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])

        renderExplanation()
        codeChanged()
        if model.viewerRole == nil, let resolveTeen {
            Task { [weak self] in
                // Unread stays generic: the copy never guesses a side (#799).
                guard let teen = try? await resolveTeen(), let self else { return }
                model.viewerRole = teen ? .teen : .supervisor
                renderExplanation()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A teen reads what is shared first: the keyboard would cover the
        // card at large text sizes (#1116). An adult types at once.
        if model.normalizedCode == nil, consentView.isHidden { codeField.becomeFirstResponder() }
    }

    static func explanation(for role: SupervisionRole?) -> String {
        guard let role else {
            // The card below says what a teen's link shares (#1116).
            return "Enter the code the other person shared. The teen always sees who supervises them, and either of you can end it."
        }
        return SupervisionCopy.acceptExplanation(teen: role == .teen)
    }

    private func renderExplanation() {
        explanation.text = Self.explanation(for: model.viewerRole)
        // A teen, or a side not read yet, is told what linking shares; an
        // adult shares nothing by accepting.
        if let title = SupervisionConsent.acceptTitle(for: model.viewerRole) {
            consentView.configure(title: title, lines: SupervisionConsent.lines(linked: false))
            consentView.isHidden = false
        } else {
            consentView.isHidden = true
        }
    }

    private func codeChanged() {
        model.code = codeField.text ?? ""
        ownTrailingBarItems.first?.isEnabled = model.canLink
    }

    static let linkID = "settings.supervisionAccept.link"

    private func linkItem() -> UIBarButtonItem {
        BarItems.title(id: Self.linkID, title: "Link", prominent: true) { [weak self] in self?.link() }
    }

    func link() {
        guard model.canLink else { return }
        // At work (#1775): the word becomes the kit's loader, under the same
        // identifier, and comes back unless the accounts are linked.
        setOwnTrailingBarItems([BarItems.busy(id: Self.linkID, label: "Linking")], animated: view.window != nil)
        codeField.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let result = await model.link()
            codeField.isEnabled = true
            if case .success? = result {} else {
                setOwnTrailingBarItems([linkItem()], animated: view.window != nil)
            }
            codeChanged()
            guard let result else { return }
            switch result {
            case .success(let supervision):
                onLinked(self, supervision)
            case .failure(let error):
                Feedback.failure(
                    SupervisionCopy.failureText(error, teen: model.viewerRole.map { $0 == .teen }, fallback: "Couldn't link accounts"),
                    from: self
                )
                codeField.becomeFirstResponder()
            }
        }
    }
}

// MARK: - How it is left (#1144)

extension SupervisionAcceptViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
