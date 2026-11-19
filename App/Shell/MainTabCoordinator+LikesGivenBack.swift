import CoreStorage
import DesignSystem
import UIKit

/// Likes the server did not take (#1775): a refused batch, an expired one, a
/// clamp. They are back in the balance and the heart has emptied; the viewer
/// hears why, over whatever screen is on top — the batch commits up to a
/// minute after the taps, often after the post is gone from the screen.
extension MainTabCoordinator {
    /// ⚠️ THE OBSERVATION IS KEPT ON THE COORDINATOR, so it lasts exactly as
    /// long as the selector registration it replaces (#2376): a dropped one
    /// would stop the toasts, silently.
    func observeLikesGivenBack() {
        likesGivenBackObservation = container.likesGivenBack.observeOnMain { [weak self] message in
            self?.likesGivenBack(message)
        }
    }

    private func likesGivenBack(_ message: String) {
        guard let screen = activeNavigationController?.topViewController else { return }
        Feedback.failure(message, from: screen)
    }
}
