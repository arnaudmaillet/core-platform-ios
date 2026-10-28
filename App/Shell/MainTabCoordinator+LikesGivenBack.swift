import DesignSystem
import Feed
import UIKit

/// Likes the server did not take (#1775): a refused batch, an expired one, a
/// clamp. They are back in the balance and the heart has emptied; the viewer
/// hears why, over whatever screen is on top — the batch commits up to a
/// minute after the taps, often after the post is gone from the screen.
extension MainTabCoordinator {
    func observeLikesGivenBack() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(likesGivenBack(_:)), name: LikeOutboxSender.likesGivenBack, object: nil
        )
    }

    @objc private func likesGivenBack(_ notification: Notification) {
        guard let back = notification.userInfo?[LikeOutboxSender.givenBackKey] as? LikesGivenBack,
              let screen = activeNavigationController?.topViewController else { return }
        Feedback.failure(back.message, from: screen)
    }
}
