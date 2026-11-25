import DesignSystem
import ThreadKit
import UIKit

/// What the way back's bubble asks of its panel: where it floats, the
/// composer it stands on, the stream it speaks for and the scroll home.
@MainActor
protocol PostDetailWayBackBubbleHost: AnyObject {
    var view: UIView! { get }
    var composeBar: CommentsInputBar { get }
    var stream: CommentStream { get }
    func scrollToStart(animated: Bool)
}

/// A text page's way back (#1929), in a bubble of its own directly above the
/// composer's own bubble (#2488, the owner 2026-11-18). Share left the slot
/// right of the field for the footer, so the way back has no slot to live in:
///
/// - the own bubble's size and glass, centred on its vertical axis,
///   `Spacing.sm` above it;
/// - the same arrow as before (up, or down for Recent's newest, #2007), and
///   a tap goes back to the stream's start;
/// - only once the reader has scrolled away, in and out with a short fade
///   and scale from the own bubble;
/// - it floats over the rows, pinned to the own bubble, so it rides the
///   keyboard with the input row, and the composer never changes size for it.
///
/// Built on first show; off, it is never built.
@MainActor
final class PostDetailWayBackBubble {
    private unowned let host: any PostDetailWayBackBubbleHost

    init(host: any PostDetailWayBackBubbleHost) {
        self.host = host
    }

    /// Whether the panel's way back lives here (a text page whose composer
    /// has no slot). Off hides the bubble.
    var isEnabled = false {
        didSet { if isEnabled != oldValue { refresh(animated: false) } }
    }

    private var button: UIButton?
    /// What the bubble shows now: nil while it is out.
    private(set) var shownDirection: Bool?

    /// Follows the stream's way back: in while the reader is away from the
    /// start, out at it.
    func refresh(animated: Bool = true) {
        let stream = host.stream
        let wanted: Bool? = isEnabled && stream.showsScrollAwayReturn ? stream.returnsDown : nil
        guard wanted != shownDirection else { return }
        let wasShown = shownDirection != nil
        shownDirection = wanted
        guard let down = wanted else { return animateOut(animated: animated) }
        let button = button ?? install()
        button.configuration?.image = UIImage(
            systemName: down ? "chevron.down" : "chevron.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        button.accessibilityLabel = down ? "Scroll to latest comment" : "Back to top"
        if !wasShown { animateIn(button, animated: animated) }
    }

    private func install() -> UIButton {
        let button = UIButton(configuration: .glass())
        button.configuration?.cornerStyle = .capsule
        button.configuration?.symbolContentTransition = UISymbolContentTransition(.replace)
        button.addAction(UIAction { [weak self] _ in self?.host.scrollToStart(animated: true) }, for: .primaryActionTriggered)
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(button)
        let anchor = host.composeBar.ownBubbleAnchor
        let side = CommentsInputBar.ownBubbleSide
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: anchor.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -Spacing.sm),
            button.widthAnchor.constraint(equalToConstant: side),
            button.heightAnchor.constraint(equalToConstant: side),
        ])
        self.button = button
        return button
    }

    /// Where the bubble comes from and goes to: small, on the own bubble.
    private var tucked: CGAffineTransform {
        let side = CommentsInputBar.ownBubbleSide
        return CGAffineTransform(translationX: 0, y: (side + Spacing.sm) / 2).scaledBy(x: 0.5, y: 0.5)
    }

    private func animateIn(_ button: UIButton, animated: Bool) {
        host.view.bringSubviewToFront(button)
        button.isHidden = false
        guard animated, button.window != nil else {
            button.alpha = 1
            button.transform = .identity
            return
        }
        button.alpha = 0
        button.transform = MotionPreference.reducesMotion ? .identity : tucked
        UIView.animate(springDuration: 0.3, bounce: 0.15) {
            button.alpha = 1
            button.transform = .identity
        }
    }

    private func animateOut(animated: Bool) {
        guard let button, !button.isHidden else { return }
        guard animated, button.window != nil else {
            button.isHidden = true
            return
        }
        let away = MotionPreference.reducesMotion ? CGAffineTransform.identity : tucked
        UIView.animate(springDuration: 0.25, bounce: 0, animations: {
            button.alpha = 0
            button.transform = away
        }, completion: { [weak self] _ in
            // A way back that came back during the exit keeps its bubble.
            guard self?.shownDirection == nil else { return }
            button.isHidden = true
            button.alpha = 1
            button.transform = .identity
        })
    }

    #if DEBUG
    /// The bubble, once built. Tests.
    var debugButton: UIButton? { button }
    #endif
}
