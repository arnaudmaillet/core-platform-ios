import DesignSystem
import UIKit

/// A single comment: monogram avatar, "Name · @handle · time" header, and body.
/// Plain `UIView` (not a cell) — appended into the post-detail content stack.
final class CommentRowView: UIView {
    private enum Metrics {
        static let avatarSize: CGFloat = 32
    }

    private let avatarView = UIView()
    private let monogramLabel = UILabel()
    private let headerLabel = UILabel()
    private let bodyLabel = UILabel()

    init(model: CommentDisplayModel) {
        super.init(frame: .zero)
        configure()
        headerLabel.text = "\(model.authorName)  \(model.metaText)"
        bodyLabel.text = model.body
        monogramLabel.text = model.monogram
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        avatarView.backgroundColor = .tertiarySystemFill
        avatarView.layer.cornerRadius = Metrics.avatarSize / 2
        avatarView.clipsToBounds = true
        monogramLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        monogramLabel.textColor = .secondaryLabel
        monogramLabel.textAlignment = .center
        monogramLabel.pin(to: avatarView)

        headerLabel.font = .preferredFont(forTextStyle: .footnote)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.textColor = .secondaryLabel
        headerLabel.numberOfLines = 1

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .label
        bodyLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [headerLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatarView, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Spacing.sm
        row.pin(to: self)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])
    }
}
