import DesignSystem
import UIKit

/// The Maps nav-bar Profile entry point: the viewer's circular avatar with an
/// unread-notifications dot (the badge surface the removed Profile tab used to
/// provide). Shows a placeholder glyph until — or instead of — the avatar.
final class ProfileAvatarButton: UIControl {
    private static let diameter: CGFloat = 32
    private static let dotDiameter: CGFloat = 10

    private let avatarView = UIImageView()
    private let unreadDot = UIView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isAccessibilityElement = true
        accessibilityLabel = "Profile"
        accessibilityTraits = .button
        accessibilityIdentifier = "profile-avatar-button"

        avatarView.contentMode = .scaleAspectFill
        avatarView.tintColor = .secondaryLabel
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = Self.diameter / 2
        avatarView.isUserInteractionEnabled = false
        avatarView.image = Self.placeholder
        avatarView.pin(to: self)
        widthAnchor.constraint(equalToConstant: Self.diameter).isActive = true
        heightAnchor.constraint(equalToConstant: Self.diameter).isActive = true

        unreadDot.backgroundColor = .systemRed
        unreadDot.layer.cornerRadius = Self.dotDiameter / 2
        // A hairline ring in the bar's background color keeps the dot legible
        // over any avatar.
        unreadDot.layer.borderWidth = 1.5
        unreadDot.layer.borderColor = UIColor.systemBackground.cgColor
        unreadDot.isUserInteractionEnabled = false
        unreadDot.isHidden = true
        unreadDot.constrain(in: self) { parent in
            unreadDot.widthAnchor.constraint(equalToConstant: Self.dotDiameter)
            unreadDot.heightAnchor.constraint(equalToConstant: Self.dotDiameter)
            unreadDot.topAnchor.constraint(equalTo: parent.topAnchor, constant: -1)
            unreadDot.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: 1)
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
