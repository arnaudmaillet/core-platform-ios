import CoreNetworking
import DesignSystem
import UIKit

/// Asks the server for an invite code (#417). One per screen: leaving and
/// coming back makes a new one, and the old one simply expires.
@MainActor
final class SupervisionInviteModel {
    enum State: Equatable {
        case loading
        case ready(SupervisionInvite)
        case failed(String)
    }

    private(set) var state: State = .loading {
        didSet { onChange?(state) }
    }
    var onChange: ((State) -> Void)?

    private let manager: any SupervisionManaging
    /// The viewer's own side.
    let role: SupervisionRole
    private var inFlight = false

    init(manager: any SupervisionManaging, role: SupervisionRole) {
        self.manager = manager
        self.role = role
    }

    func start() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        state = .loading
        do {
            state = .ready(try await manager.createSupervisionInvite(as: role))
        } catch {
            state = .failed(SupervisionCopy.failureText(error, teen: role == .teen, fallback: "Couldn't create a code"))
        }
    }
}

/// Settings → Family and Teens → Invite a Parent / Invite a Teen (#417): the
/// code to share, as text and as a QR code, with Share and Copy. The other
/// side types it, or opens the link, on their own account.
final class SupervisionInviteViewController: UIViewController {
    let model: SupervisionInviteModel
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let qrView = UIImageView()
    private let codeLabel = UILabel()
    private let expiryLabel = UILabel()
    private let spinner = AppLoaderView(size: .large)
    let failureView = EmptyStateView()
    private var shareButton: UIButton!
    private var copyButton: UIButton!
    /// Where Copy puts the code; a test reads it instead of the pasteboard.
    var copyToPasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }

    init(model: SupervisionInviteModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = SupervisionCopy.inviteTitle(teen: model.role == .teen)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        scroll.alwaysBounceVertical = true
        scroll.prefersSoftTopEdge()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = Spacing.lg
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let explanation = UILabel()
        explanation.text = SupervisionCopy.inviteExplanation(teen: model.role == .teen)
        explanation.font = .appFont(forTextStyle: .subheadline)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0
        explanation.textAlignment = .center
        stack.addArrangedSubview(explanation)

        stack.addArrangedSubview(qrHolder())

        codeLabel.font = .scaled(.monospacedSystemFont(ofSize: 30, weight: .semibold), relativeTo: .title1)
        codeLabel.adjustsFontForContentSizeCategory = true
        codeLabel.textAlignment = .center
        codeLabel.adjustsFontSizeToFitWidth = true
        codeLabel.minimumScaleFactor = 0.6
        stack.addArrangedSubview(codeLabel)

        expiryLabel.font = .appFont(forTextStyle: .footnote)
        expiryLabel.adjustsFontForContentSizeCategory = true
        expiryLabel.textColor = .secondaryLabel
        expiryLabel.textAlignment = .center
        expiryLabel.numberOfLines = 0
        stack.setCustomSpacing(Spacing.xs, after: codeLabel)
        stack.addArrangedSubview(expiryLabel)

        var share = UIButton.Configuration.filled()
        share.title = "Share Code"
        share.image = UIImage(systemName: "square.and.arrow.up")
        share.imagePadding = Spacing.sm
        share.cornerStyle = .capsule
        share.buttonSize = .large
        shareButton = UIButton(configuration: share)
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .primaryActionTriggered)
        stack.setCustomSpacing(Spacing.xl, after: expiryLabel)
        stack.addArrangedSubview(shareButton)

        var copy = UIButton.Configuration.plain()
        copy.title = "Copy Code"
        copy.buttonSize = .large
        copyButton = UIButton(configuration: copy)
        copyButton.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .primaryActionTriggered)
        stack.setCustomSpacing(Spacing.xs, after: shareButton)
        stack.addArrangedSubview(copyButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true
        view.addSubview(failureView)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        model.onChange = { [weak self] state in self?.render(state) }
        render(model.state)
        Task { await model.start() }
    }

    /// A white plate with a quiet zone, centred: scanners need the margin,
    /// and a dark background would otherwise touch the code.
    private func qrHolder() -> UIView {
        let plate = UIView()
        plate.backgroundColor = .white
        plate.layer.cornerRadius = 16
        plate.isAccessibilityElement = true
        plate.accessibilityLabel = "QR code of the invite"
        qrView.contentMode = .scaleAspectFit
        qrView.layer.magnificationFilter = .nearest
        qrView.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(qrView)
        let holder = UIView()
        plate.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(plate)
        NSLayoutConstraint.activate([
            qrView.topAnchor.constraint(equalTo: plate.topAnchor, constant: 16),
            qrView.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -16),
            qrView.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 16),
            qrView.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -16),
            plate.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            plate.topAnchor.constraint(equalTo: holder.topAnchor),
            plate.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            plate.widthAnchor.constraint(equalToConstant: 216),
            plate.heightAnchor.constraint(equalToConstant: 216),
        ])
        return holder
    }

    private func render(_ state: SupervisionInviteModel.State) {
        switch state {
        case .loading:
            scroll.isHidden = true
            failureView.isHidden = true
            spinner.startAnimating()
        case .ready(let invite):
            spinner.stopAnimating()
            failureView.isHidden = true
            scroll.isHidden = false
            codeLabel.text = invite.displayCode
            codeLabel.accessibilityLabel = invite.code.map(String.init).joined(separator: " ")
            expiryLabel.text = SupervisionCopy.expiryText(invite.expiresAt)
            qrView.image = invite.link.flatMap { QRCodeImage.makeImage(for: $0, side: 184, scale: traitCollection.displayScale) }
        case .failed(let message):
            spinner.stopAnimating()
            scroll.isHidden = true
            failureView.configure(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't Create a Code",
                subtitle: message,
                actionTitle: "Try Again",
                actionHandler: { [weak self] in
                    guard let self else { return }
                    Task { await self.model.start() }
                }
            )
            failureView.isHidden = false
        }
    }

    private var invite: SupervisionInvite? {
        if case .ready(let invite) = model.state { invite } else { nil }
    }

    private func share() {
        guard let invite else { return }
        let sheet = UIActivityViewController(
            activityItems: [SupervisionCopy.shareText(invite, teen: model.role == .teen)], applicationActivities: nil
        )
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }

    func copyCode() {
        guard let invite else { return }
        copyToPasteboard(invite.code)
        Feedback.success("Code copied", symbol: "doc.on.doc", from: self)
    }
}

// MARK: - How it is left (#1144)

extension SupervisionInviteViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
