import DesignSystem
import UIKit

/// The post's like count, under the heart inside the like PILL (#669) — the
/// snap feed's media layout and its comments panel's stake pill.
///
/// - **What it counts.** The host's number: the post's like count WITH the
///   viewer's stake in it, so a like moves it at once and an Undo takes it
///   back (product decision 2026-10-08 — unlike the cards, whose count stays
///   the post's own).
/// - **When it shows.** Always, "0" included (owner's call 2026-10-08, #680) —
///   never when the author hides like counts (#397: the host passes nil). A
///   count that appears on the viewer's own action arrives with a fade and a
///   light bounce (`animated`); a page that simply opens on one does not
///   perform.
/// - **Where it lives.** A SIBLING of the button, pinned under its heart by the
///   host, never a subview: the glass button rebuilds its configuration whole
///   on every face change and the glass may clip. It takes no touch, so a tap
///   or a hold on it still reaches the button, and it is not an accessibility
///   element — the button reads both counts.
/// - **Its ink** is the content's text ink, the heart's at rest (#680): white
///   over media, the page's on a light panel.
@MainActor
final class SnapLikeCountBadge: UIView {
    private let label = UILabel()
    /// The count drawn — nil while there is none to show.
    private(set) var count: Int64?

    /// The text's colour — the content's ink.
    var ink: UIColor {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    init(ink: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // Fixed size (#482): it lives in a pill whose size does not follow
        // the text size either.
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        label.textColor = ink
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let height: CGFloat = 16
    private static let horizontalInset: CGFloat = 5

    /// Draws `count`, "0" included; hidden at nil (a hidden count, #397).
    /// `animated` brings a badge that was not showing in with a fade and a
    /// light bounce; any other change is immediate.
    func setCount(_ count: Int64?, animated: Bool) {
        let shown = count != nil
        let wasShown = !isHidden
        self.count = shown ? count : nil
        if let count, shown { label.text = count.formattedCompact() }
        guard shown != wasShown else { return }
        layer.removeAllAnimations()
        guard shown else {
            isHidden = true
            alpha = 1
            transform = .identity
            return
        }
        isHidden = false
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            alpha = 1
            transform = .identity
            return
        }
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(
            withDuration: 0.45, delay: 0,
            usingSpringWithDamping: 0.55, initialSpringVelocity: 3,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    /// The text drawn, for tests — nil while hidden.
    var debugText: String? { isHidden ? nil : label.text }

    /// Pins the badge under the heart of a like pill: one even gap below it
    /// (`SnapActionColumn.countTopInset`), so top, heart, count and bottom are
    /// spaced alike (#680).
    func pin(underHeartOf button: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: button.centerXAnchor),
            topAnchor.constraint(equalTo: button.topAnchor, constant: SnapActionColumn.countTopInset),
        ])
    }
}
