import DesignSystem
import UIKit

/// The profile's pull-to-refresh indicator, hosted at the very top of the
/// screen — above the header, not inside the list.
///
/// ## Why this is not a `UIRefreshControl`
///
/// A `UIRefreshControl` positions itself against its scroll view's content
/// top. The profile's lists are inset below a floating header, so the stock
/// control drew its spinner *under the identity block*, mid-screen, pointing at
/// the grid rather than at the page being refreshed. There is no outer scroll
/// view to move it to: the header is a floating passthrough layer over a pager,
/// not a subview of anything that scrolls.
///
/// So the pull is read from the list — which already reports its overscroll —
/// and rendered here, pinned to the top of the screen. The list keeps ownership
/// of the gesture; this view owns only the threshold and the animation.
///
/// **Two states, deliberately, and no third.** Below the threshold the spinner
/// tracks the finger by fading and turning in proportion to the pull, so the
/// gesture feels connected. At or past it the spinner is solid. Nothing snaps,
/// and there is no "release to refresh" text — the arc filling IS the message,
/// which is the same language the platform's own control speaks.
final class ProfilePullToRefreshView: UIView {
    /// How far the list must be pulled past its top before releasing refreshes.
    ///
    /// Matches the distance `UIRefreshControl` uses, so the gesture costs the
    /// same effort here as everywhere else in the app.
    static let threshold: CGFloat = 120

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isRefreshing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Nothing to hit: the list underneath owns every touch in this band.
        isUserInteractionEnabled = false
        // ⚠️ Above the header, which is added to the same parent AFTER this and
        // whose banner is opaque across the whole top of the screen. Ordering
        // by `bringSubviewToFront` at setup time does not survive that, and the
        // spinner rendered behind the banner — invisible, while every value
        // driving it was correct. `zPosition` is what the retired
        // `UIRefreshControl` used here for the same reason.
        layer.zPosition = 10
        spinner.hidesWhenStopped = false
        spinner.alpha = 0
        spinner.constrain(in: self) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tracks an in-progress pull. `distance` is how far the list is past its
    /// top, in points.
    func setPull(_ distance: CGFloat) {
        guard !isRefreshing else { return }
        let progress = min(max(distance / Self.threshold, 0), 1)
        spinner.alpha = progress
        // Turns with the pull, so the mark reads as being drawn out rather
        // than waiting to appear.
        spinner.transform = CGAffineTransform(rotationAngle: progress * .pi)
    }

    /// Whether a release at `distance` should refresh.
    func shouldRefresh(releasedAt distance: CGFloat) -> Bool {
        !isRefreshing && distance >= Self.threshold
    }

    func beginRefreshing() {
        guard !isRefreshing else { return }
        isRefreshing = true
        spinner.transform = .identity
        spinner.startAnimating()
        UIView.animate(withDuration: 0.15) { self.spinner.alpha = 1 }
    }

    /// Ends the spin. Idempotent — the profile reports `.content` on every
    /// load, refreshed or not, so this is called far more often than it acts.
    func endRefreshing() {
        guard isRefreshing else { return }
        isRefreshing = false
        UIView.animate(withDuration: 0.2) {
            self.spinner.alpha = 0
        } completion: { _ in
            guard !self.isRefreshing else { return }
            self.spinner.stopAnimating()
        }
    }
}
