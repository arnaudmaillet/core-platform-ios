import DesignSystem
import MediaCore
import UIKit

/// The profile's identity in the navigation bar — its face, name and handle —
/// once the header's action tray has scrolled away and the viewer follows the
/// profile (the owner, 2026-10-15). The post's author pill, drawn the same
/// way: the face inset in the bar's glass, two lines that truncate.
///
/// ```
///   [ ‹ ]  [ (MH) Marcus Holt        ] [ ♥ 287 ] [ 🔔 ]
///                @marcus.holt
/// ```
///
/// It takes the bar's free width, at most (`setWidthBudget`): a long name
/// truncates first, the handle only once the name has nothing left to give.
/// A tap brings the profile's page back to its top, where the tray is.
final class ProfileBarIdentityPill: UIView {
    /// The bar's item wrapper height on iOS 26 — the box the face centres in.
    static let wrapperHeight: CGFloat = 36

    var onTap: (() -> Void)?

    private let avatar = AvatarView(diameter: AvatarImageView.bubbleDiameter, size: .avatar)
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private var maxWidth: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        avatar.picture.backgroundColor = .clear
        // The bars' one identity look, the post's author pill's too
        // (`BarIdentityStyle`): the name at a bar item's title size over the
        // handle, the name giving way first.
        BarIdentityStyle.apply(name: nameLabel, handle: handleLabel)

        let labels = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)

        let row = UIStackView(arrangedSubviews: [avatar, labels])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // The face's leading inset matches its breathing in the wrapper, so
        // it sits evenly in the glass on three sides.
        let breathing = max(0, (Self.wrapperHeight - AvatarImageView.bubbleDiameter) / 2)
        let width = widthAnchor.constraint(lessThanOrEqualToConstant: 220)
        maxWidth = width
        // 999, never required: the bar pins its wrapper with autoresizing
        // constraints on its first pass (the circular bar-button doctrine).
        let height = heightAnchor.constraint(equalToConstant: Self.wrapperHeight)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: AvatarImageView.bubbleDiameter),
            avatar.heightAnchor.constraint(equalToConstant: AvatarImageView.bubbleDiameter),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: breathing),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.md),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            width, height,
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Scrolls back to the top of the profile."
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, handle: String, monogram: String, avatarURL: URL?, pipeline: ImagePipeline) {
        nameLabel.text = name
        handleLabel.text = "@\(handle)"
        avatar.setMonogram(monogram)
        avatar.setPicture(avatarURL, pipeline: pipeline)
        accessibilityLabel = "\(name), @\(handle)"
        invalidateIntrinsicContentSize()
    }

    /// The room the bar leaves the pill: it takes its content's width, at
    /// most this, and truncates past it.
    func setWidthBudget(_ budget: CGFloat) {
        let width = max(Self.wrapperHeight, floor(budget))
        guard maxWidth?.constant != width else { return }
        maxWidth?.constant = width
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.wrapperHeight)
    }

    @objc private func tapped() { onTap?() }

    #if DEBUG
    var debugName: String? { nameLabel.text }
    var debugHandle: String? { handleLabel.text }
    var debugWidthBudget: CGFloat? { maxWidth?.constant }
    var debugNameFont: UIFont { nameLabel.font }
    var debugHandleFont: UIFont { handleLabel.font }
    #endif
}
