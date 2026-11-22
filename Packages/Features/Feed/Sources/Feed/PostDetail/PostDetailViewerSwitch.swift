import CoreModels
import ProfileInterface
import ThreadKit
import UIKit

/// What the composer's profile switcher asks of its panel (#2523): the
/// composer, whose avatar opens it, and the view model, which adopts the
/// viewer.
///
/// A view controller: the switcher is presented over it.
@MainActor
protocol PostDetailViewerSwitchHost: UIViewController {
    var composeBar: CommentsInputBar { get }
    var viewModel: PostDetailViewModel { get }
}

/// The composer avatar's profile switcher, out of `PostDetailViewController`
/// (#2523): the viewer channel's two subscriptions and the switcher's menu.
@MainActor
final class PostDetailViewerSwitch {
    private unowned let host: any PostDetailViewerSwitchHost
    /// Builds the composer avatar's profile switcher menu; nil leaves the
    /// face a plain, inert identity (`PostDetailViewController.profileSwitcher`).
    private let profileSwitcher: (any ProfileSwitcherPresenting)?
    /// The app's viewer channel (`PostDetailViewController.viewerEvents`).
    private let viewerEvents: ViewerEvents?
    /// The two subscriptions to `viewerEvents`, for this controller's
    /// lifetime: they end with it.
    private var viewerSubscriptions: [ViewerEventSubscription] = []

    init(
        host: any PostDetailViewerSwitchHost,
        profileSwitcher: (any ProfileSwitcherPresenting)?,
        viewerEvents: ViewerEvents?
    ) {
        self.host = host
        self.profileSwitcher = profileSwitcher
        self.viewerEvents = viewerEvents
    }

    /// Arms the composer avatar's profile switcher.
    ///
    /// Two independent halves, and the observer is the one that matters:
    ///
    ///  • The MENU is built from the switcher's pre-formatted rows, which
    ///    need one async `reload()` first. `makeMenu` is then synchronous, so
    ///    the menu opens fully rendered on its first frame.
    ///  • The OBSERVER adopts whatever profile becomes active, whether the
    ///    switch came from this menu or from the profile header with the
    ///    comments still open. Listening to the broadcast rather than to the
    ///    menu's own callback is what keeps the composer's face and the
    ///    identity that posts the comment from drifting apart.
    func configureProfileSwitcher() {
        viewerSubscriptions = [
            viewerEvents?.onActiveProfileChange { [weak self] id in
                self?.host.viewModel.adoptActiveViewer(id)
            },
            // Someone else is here now — most often a guest who just signed
            // up from this composer's button: the face and the name re-read,
            // and so does the menu of profiles to switch between.
            viewerEvents?.onViewerChange { [weak self] in
                self?.host.viewModel.reloadViewerIdentity()
                self?.refreshProfileMenu()
            },
        ].compactMap { $0 }

        refreshProfileMenu()
    }

    /// Reloads the switcher's profiles and counts, and arms the avatar to
    /// open the app's one switcher (#2034) — switch-only: adding a profile is
    /// the Profile feature's flow and this composer has no route to it.
    private func refreshProfileMenu() {
        guard let profileSwitcher else { return }
        Task { [weak self] in
            await profileSwitcher.reload()
            guard let self else { return }
            host.composeBar.setProfileSwitch { [weak self] source in
                guard let self else { return }
                profileSwitcher.present(
                    from: .view(source), over: host, includesAddProfile: false,
                    // The switch itself lands through the subscription above;
                    // the reload here re-marks the active row for next time.
                    onSwitch: { [weak self] in self?.refreshProfileMenu() },
                    onAddProfile: {}
                )
            }
        }
    }
}

extension PostDetailViewController: PostDetailViewerSwitchHost {}
