import DesignSystem
import UIKit

/// A single comment: monogram avatar, "Name · @handle · time" header, and body.
/// Plain `UIView` (not a cell) — appended into the post-detail content stack.
final class CommentRowView: UIView {
    private enum Metrics {
        static let avatarSize: CGFloat = 32
        /// The level-2 indentation: replies step in by one avatar column
        /// (avatar + its gap), the standard thread offset — a reply's
        /// avatar starts where its parent's text does.
        static let replyIndent: CGFloat = avatarSize + 8
    }

    /// Exposed for layout tests: the leading inset a reply row applies.
    static var replyIndent: CGFloat { Metrics.replyIndent }

    private let avatarView = UIView()
    private let monogramLabel = UILabel()
    private let headerLabel = UILabel()
    private let bodyLabel = UILabel()

    init(model: CommentDisplayModel) {
        super.init(frame: .zero)
        configure(indented: model.isReply)
        headerLabel.text = "\(model.authorName)  \(model.metaText)"
        bodyLabel.text = model.body
        monogramLabel.text = model.monogram
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(indented: Bool) {
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
        // Level-2 rows step in by the reply indent; level-1 rows fill the
        // width. The indent is the row's ONLY depth cue — same avatar,
        // same type — which is exactly the standard thread grammar.
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: indented ? Metrics.replyIndent : 0
            ),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize)
        ])
    }
}
