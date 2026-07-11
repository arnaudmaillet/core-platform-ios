import CoreNavigation
import NotificationsInterface
import ProfileInterface
import UIKit

/// Presents the signed-in viewer's profile as a sheet over the shell — the
/// destination of the Maps nav-bar avatar button (which replaced the Profile
/// tab). Profile and Notifications are composed here at the shell layer, as
/// the former Profile tab did, so the two packages stay decoupled: a bell in
/// the sheet's nav bar pushes the notifications feed onto the sheet's own stack.
///
/// The profile view controller is built per presentation and released on
/// dismissal — freshness lives in the repositories and image cache, not in a
/// retained view controller.
@MainActor
final class ProfileFlowCoordinator: NSObject, Coordinator {
    var childCoordinators: [Coordinator] = []

    private let container: AppContainer
    private let onLogout: () -> Void
    /// Fired after a user-initiated dismissal, so the owner can refresh chrome
    /// that mirrors profile state (the avatar button's unread dot — the user
    /// may have just read notifications in the sheet).
    private let onDismiss: () -> Void

    init(container: AppContainer, onLogout: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.container = container
        self.onLogout = onLogout
        self.onDismiss = onDismiss
    }

    /// Nothing to build up front; the sheet is assembled per `present` call.
    func start() {}

    func present(from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }

        let profileViewController = container.profileFeature.makeCurrentUserProfileViewController(onLogout: onLogout)
        // Activity lives inside Profile: the bell goes on the *leading* side —
        // the Profile VC owns the trailing item (its account overflow menu) and
        // resets it in viewDidLoad, which would clobber anything we set there.
        profileViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "bell"),
            primaryAction: UIAction { [weak self, weak profileViewController] _ in
                guard let self, let navigationController = profileViewController?.navigationController else { return }
                navigationController.pushViewController(
                    container.notificationsFeature.makeNotificationsViewController(),
                    animated: true
                )
            }
        )

        let navigationController = UINavigationController(rootViewController: profileViewController)
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        navigationController.presentationController?.delegate = self
        presenter.present(navigationController, animated: true)
    }
}

extension ProfileFlowCoordinator: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onDismiss()
    }
}
