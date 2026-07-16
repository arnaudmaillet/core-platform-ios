import DesignSystem
import UIKit

/// The conversation identity — `[avatar] [name]` — hosted as the navigation
/// bar's *trailing* bar item custom view, the same right-aligned identity
/// doctrine as the snap feed's author pill (`SnapAuthorIdentityView`):
/// one stable content-hugging custom view installed exactly once, wrapped by
/// the system's own glass pill; the bar's center stays clear.
///
/// Unlike the feed's pill this sits on a standard bar over `systemBackground`,
/// so it uses label colors and needs no legibility shadows.
final class ConversationIdentityView: UIView {
    /// Matches the bar's standard control height.
    private static let height: CGFloat = 40
    /// The bar's fixed item-wrapper height on iOS 26 — the box content
    /// centers in; the avatar's leading breathing derives from it.
    private static let barItemWrapperHeight: CGFloat = 36
    /// Long peer names truncate here rather than crowding the back item.
    private static let maxWidth: CGFloat = 240

    /// Fired when the identity is tapped — the host decides the destination.
    var onTapped: (() -> Void)?

    private let avatarView = UIView()
    private let monogramLabel = UILabel()
    private let nameLabel = UILabel()

    init() {
        super.init(frame: .zero)

        // Whole-pill target (feed doctrine): one recognizer on the container,
        // so avatar and name are a single, generous hit area.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(identityTapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button

        // Same monogram language as the conversation list's rows, at the
        // shared bar-avatar diameter.
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.layer.cornerRadius = AvatarImageView.barDiameter / 2
        avatarView.clipsToBounds = true
        avatarView.widthAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: AvatarImageView.barDiameter).isActive = true
        monogramLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label

        let row = UIStackView(arrangedSubviews: [avatarView, nameLabel])
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .center
        // The name is the designated width absorber (feed doctrine): its
        // content is leading-aligned, so any width the bar hands the pill
        // beyond natural content becomes invisible trailing space.
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)

        // Avatar breathing: the wrapper renders 36pt tall with the avatar
        // centered; the same computed gap leading keeps the circle uniformly
        // inset in the system pill. A larger trailing inset gives the name
        // room against the pill's rounded end.
        let avatarBreathing = (Self.barItemWrapperHeight - AvatarImageView.barDiameter) / 2
        row.constrain(in: self) { parent in
            row.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: avatarBreathing)
            row.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.md)
            row.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }
        // 999, not required: the bar wraps items in its own fixed-height
        // container and a required height fights it (runtime constraint break).
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth).isActive = true

        setIdentity(name: "", monogram: "?", animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func identityTapped() {
        onTapped?()
    }

    /// Content-sized by design, so hydration re-negotiates the bar item's
    /// width; drive the re-measure through a short eased pass (feed doctrine)
    /// so the pill glides instead of snapping. Warm-start binds happen before
    /// the view is in a window (mid-push `viewDidLoad`) and take the direct,
    /// animation-free branch — present at the transition's first frame.
    func setIdentity(name: String, monogram: String, animated: Bool = true) {
        // Idempotent: an async refresh confirming the cached identity must
        // not replay the cross-fade.
        guard name != nameLabel.text || monogram != monogramLabel.text else { return }
        accessibilityLabel = name
        guard animated, window != nil else {
            nameLabel.text = name
            monogramLabel.text = monogram
            return
        }
        UIView.transition(with: self, duration: 0.18,
                          options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.nameLabel.text = name
            self.monogramLabel.text = monogram
        }
        setNeedsLayout()
        var bar: UIView? = superview
        while let view = bar, !(view is UINavigationBar) { bar = view.superview }
        let host = bar ?? superview
        host?.setNeedsLayout()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            host?.layoutIfNeeded()
        }
    }
}
