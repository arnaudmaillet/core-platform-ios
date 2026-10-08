import DesignSystem
import UIKit

/// The post's like count, as a small capsule on the like button's
/// bottom-trailing corner (#668) — the snap feed's media layout and its
/// comments panel's stake bubble.
///
/// - **What it counts.** The host's number: the post's like count WITH the
///   viewer's stake in it, so a like moves it at once and an Undo takes it
///   back (product decision 2026-10-08 — unlike the cards, whose count stays
///   the post's own).
/// - **When it shows.** Only above zero, and never when the author hides like
///   counts (#397: the host passes nil). A count that leaves zero on the
///   viewer's own like arrives with a fade and a light bounce (`animated`); a
///   page that simply opens on a count does not perform.
/// - **Where it lives.** A SIBLING of the button, pinned to its corner by the
///   host, never a subview: the glass button rebuilds its configuration whole
///   on every face change and the glass may clip. It takes no touch, so a tap
///   or a hold on the corner still reaches the button, and it is not an
///   accessibility element — the button reads both counts.
///
/// Neutral ink, not red: the liked heart beside it is the red one.
@MainActor
final class SnapLikeCountBadge: UIView {
    /// Where the count sits.
    enum Style {
        /// A capsule on the button's corner (#668).
        case corner
        /// Bare text under the heart, inside the like pill (#669), in `ink`.
        case inline(ink: UIColor)
    }

    private let label = UILabel()
    private let style: Style
    /// The count drawn — nil while there is none to show.
    private(set) var count: Int64?

    init(style: Style = .corner) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // Fixed size (#482): it lives on a bubble whose size does not follow
        // the text size either.
        switch style {
        case .corner:
            backgroundColor = UIColor.black.withAlphaComponent(0.6)
            layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
            layer.borderWidth = 0.5
            layer.cornerCurve = .continuous
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
            label.textColor = .white
        case .inline(let ink):
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            label.textColor = ink
        }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        if case .corner = style { layer.cornerRadius = bounds.height / 2 }
    }

    /// Draws `count`: hidden at nil or zero. `animated` brings a badge that
    /// was not showing in with a fade and a light bounce; any other change is
    /// immediate.
    func setCount(_ count: Int64?, animated: Bool) {
        let shown = count.map { $0 > 0 } ?? false
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

    /// Pins the badge on `button`'s bottom-trailing corner, inside `container`
    /// (the button's own superview) and never past `container`'s trailing edge.
    func pin(toCornerOf button: UIView, in container: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        let centered = centerXAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.cornerInset)
        // A long count ("12.3K") slides inward rather than off the screen.
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centered,
            trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            centerYAnchor.constraint(equalTo: button.bottomAnchor, constant: -Self.cornerInset),
        ])
    }

    /// How far inside the button's corner the badge's centre sits.
    private static let cornerInset: CGFloat = 4

    /// Pins the badge under the heart of a like PILL (#669): the heart sits
    /// centred in the pill's top square (`squareSide`), the count right below.
    func pin(underHeartOf button: UIView, squareSide: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: button.centerXAnchor),
            topAnchor.constraint(equalTo: button.topAnchor, constant: squareSide / 2 + Self.heartHalfHeight),
        ])
    }

    /// Half the heart glyph's height at the bubbles' 15 pt symbol size, and
    /// the breath under it.
    private static let heartHalfHeight: CGFloat = 9
}
