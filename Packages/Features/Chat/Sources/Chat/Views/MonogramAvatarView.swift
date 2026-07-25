import UIKit

/// The chat surfaces' identity disc: initials on a translucent fill, clipped
/// to a circle at any diameter.
///
/// `chat.v1` members carry ids only and the inbox never pays for an avatar
/// fetch per row, so initials *are* the identity here — extracted into one
/// view because the conversation list and the request list have to render the
/// same disc at the same size or the two tabs read as different products.
final class MonogramAvatarView: UIView {
    /// The inbox row diameter, shared by every list that shows a person.
    static let rowDiameter: CGFloat = 48

    private let label = UILabel()

    init(diameter: CGFloat = MonogramAvatarView.rowDiameter) {
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func setMonogram(_ monogram: String) {
        label.text = monogram
    }
}
