import DesignSystem
import UIKit

/// The Maps nav-bar Notifications entry point: a bell glyph carrying the
/// unread-notifications dot, seated to the left of the profile avatar. The
/// badge moved here from the avatar; the bar wraps this custom view in the same
/// glass capsule as the avatar and the create "+", so the three read as one set.
///
/// Mirrors `ProfileAvatarButton`'s footprint and dot so the two trailing items
/// sit at an identical size and their badges can't drift apart.
final class NotificationsBellButton: UIControl {
    private static let diameter = AvatarImageView.barDiameter
    private static let dotDiameter: CGFloat = 10

    private let glyphView = UIImageView()
    private let unreadDot = UIView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isAccessibilityElement = true
        accessibilityLabel = "Notifications"
        accessibilityTraits = .button
        accessibilityIdentifier = "notifications-bell-button"

        glyphView.image = Self.bell
        glyphView.contentMode = .center
        glyphView.isUserInteractionEnabled = false
        // Centered, never edge-pinned: the bar's item wrapper renders custom
        // views in its own fixed-height box (36pt on iOS 26) and breaks required
        // external constraints, so an edge-pinned glyph silently stretches. The
        // control's own size sits at 999 to yield to that wrapper — same rule as
        // `ProfileAvatarButton`.
        glyphView.constrain(in: self) { parent in
            glyphView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            glyphView.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        for constraint in [
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
        ] {
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
        }

        unreadDot.backgroundColor = .systemRed
        unreadDot.layer.cornerRadius = Self.dotDiameter / 2
        // A hairline ring in the bar's background color keeps the dot legible
        // over the glass capsule.
        unreadDot.layer.borderWidth = 1.5
        unreadDot.layer.borderColor = UIColor.systemBackground.cgColor
        unreadDot.isUserInteractionEnabled = false
        unreadDot.isHidden = true
        // Anchored to the glyph, hugging the top-trailing of the bell.
        unreadDot.constrain(in: self) { _ in
            unreadDot.widthAnchor.constraint(equalToConstant: Self.dotDiameter)
            unreadDot.heightAnchor.constraint(equalToConstant: Self.dotDiameter)
            unreadDot.topAnchor.constraint(equalTo: glyphView.topAnchor, constant: -3)
            unreadDot.trailingAnchor.constraint(equalTo: glyphView.trailingAnchor, constant: 5)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.diameter, height: Self.diameter)
    }

    override var isHighlighted: Bool {
        didSet { glyphView.alpha = isHighlighted ? 0.6 : 1 }
    }

    func setHasUnread(_ hasUnread: Bool) {
        unreadDot.isHidden = !hasUnread
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor doesn't follow dynamic-color changes on its own.
        unreadDot.layer.borderColor = UIColor.systemBackground.cgColor
    }

    private static let bell = UIImage(
        systemName: "bell",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    )
}
