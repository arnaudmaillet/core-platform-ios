import UIKit

/// The app's identity disc: initials on a translucent fill, clipped to a
/// circle at any diameter.
///
/// Lives here rather than in a feature because every person row in the app is
/// the same disc at the same size — the chat inbox, the message requests list,
/// the compose picker, the follow suggestions, and the profile's follower /
/// following lists. Two features drawing their own would drift apart, and the
/// lists read as different products the moment they do.
///
/// Initials, not an image, is the *default* state on purpose: `chat.v1` members
/// and `social_graph.v1` edges carry ids only, so a row can always render an
/// identity even before (or without) an avatar fetch. Callers that do have a
/// URL overlay an `AvatarImageView` pinned to this view, leaving the monogram
/// behind it as the permanent fallback.
public final class MonogramAvatarView: UIView {
    /// The list-row diameter, shared by every surface that shows a person.
    public static let rowDiameter: CGFloat = 48

    private let label = UILabel()

    public init(diameter: CGFloat = MonogramAvatarView.rowDiameter) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        clipsToBounds = true
        label.font = .systemFont(ofSize: diameter * 0.375, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.pin(to: self)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    public func setMonogram(_ monogram: String) {
        label.text = monogram
    }
}
