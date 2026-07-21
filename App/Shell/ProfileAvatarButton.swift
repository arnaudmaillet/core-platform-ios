import DesignSystem
import UIKit

/// The Maps nav-bar Profile entry point: the viewer's circular avatar with an
/// unread-notifications dot (the badge surface the removed Profile tab used to
/// provide). Shows a placeholder glyph until — or instead of — the avatar.
///
/// A lightweight `UIControl` (matching the rest of the header chrome): a short
/// tap opens the profile via `.touchUpInside`; the shell attaches an explicit
/// `UILongPressGestureRecognizer` for the profile switcher (neither
/// `UIContextMenuInteraction` nor `UIButton.menu` fired reliably for a custom
/// view inside a bar item).
final class ProfileAvatarButton: UIControl {
    /// Shared with every other bar avatar (e.g. the snap feed's author pill)
    /// via the design system, so the surfaces cannot drift apart.
    private static let diameter = AvatarImageView.barDiameter
    private static let dotDiameter: CGFloat = 10

    private let avatarView = AvatarImageView()
    private let unreadDot = UIView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isAccessibilityElement = true
        accessibilityLabel = "Profile"
        accessibilityTraits = .button
        accessibilityIdentifier = "profile-avatar-button"

        avatarView.tintColor = .secondaryLabel
        avatarView.isUserInteractionEnabled = false
        avatarView.image = Self.placeholder
        // The avatar is fixed at the shared diameter and *centered*, never
        // edge-pinned: the bar's item wrapper renders custom views in its own
        // fixed-height box (36pt on iOS 26) and breaks required external
        // constraints, so an edge-pinned avatar silently stretched to 36pt —
        // and with a hardcoded radius, out of round. Centered, it keeps the
        // exact diameter the feed's author pill uses whatever the wrapper does.
        avatarView.constrain(in: self) { parent in
            avatarView.widthAnchor.constraint(equalToConstant: Self.diameter)
            avatarView.heightAnchor.constraint(equalToConstant: Self.diameter)
            avatarView.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            avatarView.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, not required: yield to the wrapper's own sizing (see above).
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
        // over any avatar.
        unreadDot.layer.borderWidth = 1.5
        unreadDot.layer.borderColor = UIColor.systemBackground.cgColor
        unreadDot.isUserInteractionEnabled = false
        unreadDot.isHidden = true
        // Anchored to the avatar, not the control: the wrapper may size the
        // control differently, but the dot must hug the visible circle.
        unreadDot.constrain(in: self) { _ in
            unreadDot.widthAnchor.constraint(equalToConstant: Self.dotDiameter)
            unreadDot.heightAnchor.constraint(equalToConstant: Self.dotDiameter)
            unreadDot.topAnchor.constraint(equalTo: avatarView.topAnchor, constant: -1)
            unreadDot.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.diameter, height: Self.diameter)
    }

    override var isHighlighted: Bool {
        didSet { avatarView.alpha = isHighlighted ? 0.6 : 1 }
    }

    func setAvatar(_ image: UIImage?) {
        avatarView.image = image ?? Self.placeholder
    }

    func setHasUnread(_ hasUnread: Bool) {
        unreadDot.isHidden = !hasUnread
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // CGColor doesn't follow dynamic-color changes on its own.
        unreadDot.layer.borderColor = UIColor.systemBackground.cgColor
    }

    private static let placeholder = UIImage(
        systemName: "person.crop.circle",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter, weight: .regular)
    )
}
