import DesignSystem
import UIKit

/// What the Profile and Messages tabs show a guest: there is no profile and no
/// inbox without an account, so the tab says so and offers the way in.
///
/// Deliberately plain for now — the guest surfaces (#442) give each tab its own
/// wording, the settings gear and the welcome gift; the sign-up sheet that
/// replays the action a guest started is #441. This is the root the shell
/// swaps in and out as the viewer signs in and out (`MainTabCoordinator`).
@MainActor
final class GuestSignInViewController: UIViewController {
    private let symbolName: String
    private let headline: String
    private let message: String
    private let onSignIn: () -> Void
    private let emptyState = EmptyStateView()

    init(symbolName: String, title: String, message: String, onSignIn: @escaping () -> Void) {
        self.symbolName = symbolName
        self.headline = title
        self.message = message
        self.onSignIn = onSignIn
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        emptyState.configure(
            symbolName: symbolName,
            title: headline,
            subtitle: message,
            actionTitle: "Log in or sign up",
            actionHandler: { [onSignIn] in onSignIn() }
        )
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }
}
